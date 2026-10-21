import 'package:flutter/material.dart';

import 'camera_screen.dart';
import 'editor_screen.dart';
import 'ocr.dart';
import 'pages.dart';
import 'save_sheet.dart';
import 'storage.dart';
import 'theme.dart';

/// 문서 하나를 여는 화면: 페이지 목록, 편집, 더 스캔하기, 순서 바꾸기, 저장.
/// 바뀔 때마다 기기에 자동 보관된다.
class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.doc, this.scanFirst = false, this.galleryFirst = false});

  final ScanDoc doc;

  /// 새 문서면 바로 촬영부터
  final bool scanFirst;

  /// 새 문서를 갤러리 사진으로 시작
  final bool galleryFirst;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  List<ScanPage> get _pages => widget.doc.pages;
  bool _reorder = false;

  @override
  void initState() {
    super.initState();
    _runOcr();
    if (widget.scanFirst) WidgetsBinding.instance.addPostFrameCallback((_) => _scan(first: true, gallery: widget.galleryFirst));
  }

  void _persist() => Store.save(widget.doc);

  Future<void> _rename() async {
    final ctl = TextEditingController(text: widget.doc.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('문서 이름'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('확인')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => widget.doc.name = name);
    _persist();
  }
  bool _busy = false;
  String? _busyText;

  /// 선택 모드에서 고른 페이지 (비어 있으면 선택 모드 아님)
  final Set<ScanPage> _selected = {};

  /// 글자 인식이 안 된 페이지를 뒤에서 차례로 OCR 한다.
  Future<void> _ocrQueue = Future.value();
  final Set<ScanPage> _queued = {};

  void _runOcr() {
    for (final p in _pages.where((p) => p.ocr == null && !_queued.contains(p))) {
      _queued.add(p);
      _ocrQueue = _ocrQueue.then((_) async {
        final jpg = p.jpg;
        try {
          final r = await Ocr.recognize(jpg);
          if (identical(p.jpg, jpg)) p.ocr = r; // 그 사이 필터를 바꿨으면 버린다
        } catch (e) {
          p.ocr = OcrResult([]);
          debugPrint('OCR 실패: $e');
        }
        _queued.remove(p);
        _persist();
        if (mounted) setState(() {});
        if (p.ocr == null) _runOcr();
      });
    }
  }

  /// 연속 촬영(자동 인식) → 편집 화면 → 문서에 추가.
  Future<void> _scan({bool first = false, bool gallery = false}) async {
    final nav = Navigator.of(context);
    final fresh = await nav
        .push<List<ScanPage>>(MaterialPageRoute(builder: (_) => CameraScreen(galleryFirst: gallery)));
    if (fresh != null && fresh.isNotEmpty && mounted) {
      await nav.push(MaterialPageRoute(builder: (_) => EditorScreen(pages: fresh)));
    }
    if (fresh == null || fresh.isEmpty || !mounted) {
      // 새 문서인데 아무것도 안 찍었으면 닫기
      if (first && _pages.isEmpty && mounted) nav.pop();
      return;
    }
    setState(() => _pages.addAll(fresh));
    _persist();
    _runOcr();
  }

  Future<void> _edit(int i) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => EditorScreen(pages: _pages, initial: i)));
    setState(() => _selected.removeWhere((p) => !_pages.contains(p)));
    _persist();
    _runOcr();
  }

  void _toggle(int i) => setState(() {
        final p = _pages[i];
        if (!_selected.remove(p)) _selected.add(p);
      });

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await showSaveSheet(context, _pages.length, _selected.length, widget.doc.name);
    if (res == null) return;
    final (o, target) = res;
    final targets = o.onlySelected && _selected.isNotEmpty
        ? _pages.where(_selected.contains).toList()
        : List.of(_pages);

    setState(() => _busy = true);
    try {
      // 글자 검색 PDF나 TXT는 OCR이 끝나야 한다
      final needOcr = o.format == SaveFormat.txt || (o.format == SaveFormat.pdf && o.searchable);
      if (needOcr && targets.any((p) => p.ocr == null)) {
        setState(() => _busyText = '글자 인식 마무리 중…');
        _runOcr();
        await _ocrQueue;
      }
      setState(() => _busyText = '저장 파일 만드는 중…');
      final msg = await runSave(targets, o, target);
      if (msg != null) {
        messenger.showSnackBar(SnackBar(
            content: Row(children: [
          const Icon(Icons.check_circle, color: AppColors.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(msg)),
        ])));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('저장 실패: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pages.where((p) => p.ocr == null).length;
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: selecting
            ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
            : null,
        title: selecting
            ? Text('${_selected.length}개 선택')
            : _reorder
                ? const Text('순서 바꾸기')
                : GestureDetector(
                    onTap: _rename,
                    child: Row(children: [
                      Flexible(child: Text(widget.doc.name, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 6),
                      const Icon(Icons.edit_outlined, size: 18, color: AppColors.muted),
                    ]),
                  ),
        actions: [
          if (_reorder)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: () {
                  setState(() => _reorder = false);
                  _persist();
                },
                child: const Text('완료'),
              ),
            )
          else ...[
          if (!selecting && _pages.length > 1)
            IconButton(
              tooltip: '순서 바꾸기',
              icon: const Icon(Icons.swap_vert_rounded),
              onPressed: () => setState(() => _reorder = true),
            ),
          if (selecting) ...[
            IconButton(
              tooltip: '모두 선택',
              icon: const Icon(Icons.select_all_rounded),
              onPressed: () => setState(() => _selected.addAll(_pages)),
            ),
            IconButton(
              tooltip: '삭제',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () {
                setState(() {
                  _pages.removeWhere(_selected.contains);
                  _selected.clear();
                });
                _persist();
              },
            ),
          ],
          ],
        ],
      ),
      body: Stack(children: [
        _reorder
            ? _ReorderList(pages: _pages, onChanged: () => setState(() {}))
            : _pages.isEmpty
            ? const SizedBox()
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    pending > 0
                        ? '${_pages.length}페이지 · 글자 인식 중 ($pending)'
                        : selecting
                            ? '저장할 페이지를 눌러 고르세요'
                            : '${_pages.length}페이지 · 눌러서 편집 · 길게 눌러 골라 저장',
                    style: const TextStyle(color: AppColors.muted, fontSize: 13),
                  ),
                ),
                Expanded(
                  child: PageGrid(
                    pages: _pages,
                    selected: _selected,
                    onTap: (i) => selecting ? _toggle(i) : _edit(i),
                    onLongPress: _toggle,
                  ),
                ),
              ]),
        if (_busy)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                      color: AppColors.surface, borderRadius: BorderRadius.circular(20)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    if (_busyText != null) ...[const SizedBox(height: 16), Text(_busyText!)],
                  ]),
                ),
              ),
            ),
          ),
      ]),
      // 다음 행동: 저장(주) · 더 스캔(보조). 선택 중이면 선택한 페이지 저장.
      bottomNavigationBar: _reorder || _pages.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: Colors.white10)),
                ),
                child: Row(children: [
                  if (!selecting) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _scan,
                        icon: const Icon(Icons.add_a_photo_outlined),
                        label: const Text('더 스캔'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(selecting ? '선택한 ${_selected.length}장 저장' : '저장 (PDF·JPG)'),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }
}


/// 끌어서 순서를 바꾸는 목록.
class _ReorderList extends StatelessWidget {
  const _ReorderList({required this.pages, required this.onChanged});

  final List<ScanPage> pages;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      itemCount: pages.length,
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) {
        pages.insert(to, pages.removeAt(from));
        onChanged();
      },
      itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
        key: ObjectKey(pages[i]),
        index: i,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(pages[i].jpg, width: 54, height: 72, fit: BoxFit.cover, cacheWidth: 120),
            ),
            const SizedBox(width: 16),
            Text('${i + 1}페이지', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            ReorderableDragStartListener(
              index: i,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.drag_handle_rounded, color: AppColors.muted),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
