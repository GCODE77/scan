import 'package:flutter/material.dart';

import 'camera_screen.dart';
import 'editor_screen.dart';
import 'ocr.dart';
import 'pages.dart';
import 'save_sheet.dart';
import 'theme.dart';

void main() => runApp(const BookScanApp());

class BookScanApp extends StatelessWidget {
  const BookScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '북스캔',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<ScanPage> _pages = [];
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
        if (mounted) setState(() {});
        if (p.ocr == null) _runOcr();
      });
    }
  }

  /// 연속 촬영(자동 인식) → 편집 화면 → 문서에 추가.
  Future<void> _scan() async {
    final nav = Navigator.of(context);
    final fresh = await nav.push<List<ScanPage>>(MaterialPageRoute(builder: (_) => const CameraScreen()));
    if (fresh == null || fresh.isEmpty || !mounted) return;
    await nav.push(MaterialPageRoute(builder: (_) => EditorScreen(pages: fresh)));
    setState(() => _pages.addAll(fresh));
    _runOcr();
  }

  Future<void> _edit(int i) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => EditorScreen(pages: _pages, initial: i)));
    setState(() => _selected.removeWhere((p) => !_pages.contains(p)));
    _runOcr();
  }

  void _toggle(int i) => setState(() {
        final p = _pages[i];
        if (!_selected.remove(p)) _selected.add(p);
      });

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await showSaveSheet(context, _pages.length, _selected.length);
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
            : Row(children: [
                ShaderMask(
                  shaderCallback: AppColors.gradient.createShader,
                  child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(width: 10),
                const Text('북스캔'),
              ]),
        actions: [
          if (selecting) ...[
            IconButton(
              tooltip: '모두 선택',
              icon: const Icon(Icons.select_all_rounded),
              onPressed: () => setState(() => _selected.addAll(_pages)),
            ),
            IconButton(
              tooltip: '삭제',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => setState(() {
                _pages.removeWhere(_selected.contains);
                _selected.clear();
              }),
            ),
          ],
          if (_pages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.download_rounded, size: 20),
                label: const Text('저장', style: TextStyle(fontSize: 14)),
              ),
            ),
        ],
      ),
      body: Stack(children: [
        _pages.isEmpty
            ? const _Empty()
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    pending > 0
                        ? '${_pages.length}페이지 · 글자 인식 중 ($pending)'
                        : selecting
                            ? '눌러서 선택 · 저장 버튼으로 선택한 페이지만 저장'
                            : '${_pages.length}페이지 · 눌러서 편집, 길게 눌러 선택',
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
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: selecting
          ? null
          : GradientButton(
              icon: Icons.document_scanner_rounded,
              label: _pages.isEmpty ? '스캔 시작' : '더 스캔하기',
              onTap: _busy ? null : _scan,
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 120),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [
                AppColors.accent.withValues(alpha: .25),
                AppColors.accent2.withValues(alpha: .1),
              ]),
            ),
            child: const Icon(Icons.menu_book_rounded, size: 56, color: AppColors.accent),
          ),
          const SizedBox(height: 28),
          const Text('책을 스캐너처럼',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
          const SizedBox(height: 10),
          const Text(
            '셔터만 누르세요.\n휘어진 페이지를 반듯하게 펴고, 양면은 나누고,\n글자까지 읽어 드립니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, height: 1.6),
          ),
        ]),
      ),
    );
  }
}
