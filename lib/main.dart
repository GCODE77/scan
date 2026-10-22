import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'document_screen.dart';
import 'save_sheet.dart';
import 'storage.dart';
import 'theme.dart';
import 'updater.dart';

void main() => runApp(const BookScanApp());

class BookScanApp extends StatelessWidget {
  const BookScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '북스캔',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const LibraryScreen(),
    );
  }
}

/// 첫 화면: 보관된 문서 목록.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ScanDoc>? _docs;
  String _query = '';
  bool _searching = false;

  /// 선택 모드 (여러 문서 골라서 삭제)
  bool _selectMode = false;
  final Set<String> _selected = {};

  void _toggle(ScanDoc d) => setState(() {
        if (!_selected.remove(d.id)) _selected.add(d.id);
      });

  void _exitSelect() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  Future<void> _deleteSelected() async {
    final targets = _docs!.where((d) => _selected.contains(d.id)).toList();
    if (targets.isEmpty) return;
    final pages = targets.fold<int>(0, (s, d) => s + d.pageCount);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('문서 ${targets.length}개를 삭제할까요?'),
        content: Text('모두 $pages페이지입니다. 삭제하면 되돌릴 수 없습니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok != true) return;
    for (final d in targets) {
      await Store.delete(d);
    }
    _exitSelect();
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('문서 ${targets.length}개를 삭제했습니다')));
    }
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    // 새 버전이 GitHub에 올라와 있으면 알려 준다
    WidgetsBinding.instance.addPostFrameCallback((_) => Updater.checkAndPrompt(context));
  }

  Future<void> _refresh() async {
    final docs = await Store.list();
    if (mounted) setState(() => _docs = docs);
  }

  Future<void> _open(ScanDoc doc, {bool scanFirst = false, bool gallery = false}) async {
    if (!scanFirst) await Store.load(doc);
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(
            builder: (_) => DocumentScreen(doc: doc, scanFirst: scanFirst, galleryFirst: gallery)));
    final count = doc.pages.length;
    // 저장이 끝난 뒤에 메모리에서 내린다. 페이지가 하나도 없는 문서는 보관함에서도 지운다.
    if (count > 0) {
      await Store.save(doc);
    } else {
      await Store.delete(doc);
    }
    doc.pages = [];
    _refresh();
  }

  Future<void> _menu(ScanDoc doc) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(doc.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${doc.pageCount}페이지 · ${_date(doc.updated)}',
                style: const TextStyle(color: AppColors.muted)),
          ),
          const Divider(height: 1),
          ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('공유하기'),
              subtitle: const Text('카카오톡·메일 등', style: TextStyle(color: AppColors.muted)),
              onTap: () => Navigator.pop(s, 'share')),
          ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('이름 바꾸기'),
              onTap: () => Navigator.pop(s, 'rename')),
          ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
              title: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.pop(s, 'delete')),
        ]),
      ),
    );
    if (!mounted) return;
    if (action == 'share') {
      await Store.load(doc);
      if (mounted) await shareDocument(context, doc.pages, doc.name);
      doc.pages = [];
      return;
    }
    if (action == 'rename') {
      final ctl = TextEditingController(text: doc.name);
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
      if (name != null && name.isNotEmpty) {
        await Store.rename(doc, name);
        doc.pages = [];
        _refresh();
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('문서를 삭제할까요?'),
          content: Text('\'${doc.name}\' (${doc.pageCount}페이지)\n삭제하면 되돌릴 수 없습니다.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(d, true),
                child: const Text('삭제')),
          ],
        ),
      );
      if (ok == true) {
        await Store.delete(doc);
        _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs
        ?.where((d) => _query.isEmpty || d.name.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelect),
              title: Text('${_selected.length}개 선택'),
              actions: [
                TextButton.icon(
                  icon: Icon(_selected.length == (docs?.length ?? 0)
                      ? Icons.deselect_rounded
                      : Icons.select_all_rounded),
                  label: Text(_selected.length == (docs?.length ?? 0) ? '선택 해제' : '전체 선택'),
                  onPressed: () => setState(() {
                    if (_selected.length == (docs?.length ?? 0)) {
                      _selected.clear();
                    } else {
                      _selected.addAll(docs!.map((d) => d.id));
                    }
                  }),
                ),
              ],
            )
          : AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: '문서 이름 검색', filled: false, border: InputBorder.none),
                onChanged: (v) => setState(() => _query = v),
              )
            : Row(children: [
                const AppLogo(size: 30),
                const SizedBox(width: 10),
                const Text('북스캔'),
              ]),
        actions: [
          if (_docs?.isNotEmpty ?? false)
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search_rounded),
              onPressed: () => setState(() {
                _searching = !_searching;
                _query = '';
              }),
            ),
          if (_docs?.isNotEmpty ?? false)
            IconButton(
              tooltip: '선택',
              icon: const Icon(Icons.checklist_rounded),
              onPressed: () => setState(() => _selectMode = true),
            ),
          IconButton(
            tooltip: '앱 정보',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => Updater.showAbout(context),
          ),
        ],
      ),
      body: docs == null
          ? const Center(child: CircularProgressIndicator())
          : _docs!.isEmpty
              ? const _Empty()
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2, childAspectRatio: 0.66, mainAxisSpacing: 16, crossAxisSpacing: 16),
                    itemCount: docs.length,
                    itemBuilder: (_, i) => _DocCard(
                      doc: docs[i],
                      selectMode: _selectMode,
                      selected: _selected.contains(docs[i].id),
                      onTap: () => _selectMode ? _toggle(docs[i]) : _open(docs[i]),
                      // 길게 누르면 선택 모드로
                      onLongPress: () {
                        HapticFeedback.selectionClick();
                        setState(() => _selectMode = true);
                        _toggle(docs[i]);
                      },
                      onMenu: () => _menu(docs[i]),
                    ),
                  ),
                ),
      bottomNavigationBar: !_selectMode
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: const BoxDecoration(
                    color: AppColors.surface, border: Border(top: BorderSide(color: Colors.white10))),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                  onPressed: _selected.isEmpty ? null : _deleteSelected,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(_selected.isEmpty ? '삭제할 문서를 고르세요' : '${_selected.length}개 삭제'),
                ),
              ),
            ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      // 주 행동: 스캔 시작 · 보조: 갤러리 사진으로 시작
      floatingActionButton: _selectMode ? null : Row(mainAxisSize: MainAxisSize.min, children: [
        Material(
          color: AppColors.card,
          shape: const CircleBorder(side: BorderSide(color: Colors.white24)),
          child: IconButton(
            tooltip: '사진에서 가져오기',
            padding: const EdgeInsets.all(14),
            icon: const Icon(Icons.photo_library_rounded),
            onPressed: () => _open(Store.newDoc(), scanFirst: true, gallery: true),
          ),
        ),
        const SizedBox(width: 12),
        GradientButton(
          icon: Icons.document_scanner_rounded,
          label: '스캔 시작',
          onTap: () => _open(Store.newDoc(), scanFirst: true),
        ),
      ]),
    );
  }
}

String _date(DateTime d) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '오늘 ${two(d.hour)}:${two(d.minute)}';
  }
  return '${d.year}.${two(d.month)}.${two(d.day)}';
}

class _DocCard extends StatelessWidget {
  const _DocCard({
    required this.doc,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
    this.selectMode = false,
    this.selected = false,
  });

  final ScanDoc doc;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onMenu;
  final bool selectMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Stack(clipBehavior: Clip.none, children: [
            // 뒤에 겹친 종이 (여러 페이지 느낌)
            if (doc.pageCount > 1)
              Positioned.fill(
                left: 6,
                right: -6,
                top: -6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: AppColors.card, borderRadius: BorderRadius.circular(16)),
                ),
              ),
            Positioned.fill(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6))],
                ),
                child: doc.thumbPath == null
                    ? const Icon(Icons.description_outlined, color: AppColors.muted, size: 40)
                    : Image.file(File(doc.thumbPath!),
                        fit: BoxFit.cover,
                        // 같은 경로라도 수정되면 새로 읽도록
                        key: ValueKey('${doc.thumbPath}${doc.updated}')),
              ),
            ),
            // 선택 표시 / 메뉴 버튼
            if (selectMode)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: selected ? AppColors.accent.withValues(alpha: .18) : Colors.black26,
                    border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 3),
                  ),
                ),
              ),
            Positioned(
              right: 4,
              top: 4,
              child: selectMode
                  ? Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                          color: selected ? AppColors.accent : Colors.white,
                          size: 26,
                          shadows: const [Shadow(blurRadius: 6)]),
                    )
                  : Material(
                      color: Colors.black45,
                      shape: const CircleBorder(),
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.more_vert_rounded, size: 20),
                        onPressed: onMenu,
                      ),
                    ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .7), borderRadius: BorderRadius.circular(8)),
                child: Text('${doc.pageCount}p',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text(doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 2),
        Text(_date(doc.updated), style: const TextStyle(color: AppColors.muted, fontSize: 12)),
      ]),
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
          // 아이콘에 은은한 빛
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: .35), blurRadius: 40)],
            ),
            child: const AppLogo(size: 120),
          ),
          const SizedBox(height: 28),
          const Text('책을 스캐너처럼',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.5)),
          const SizedBox(height: 10),
          const Text(
            '셔터만 누르세요. 휘어진 페이지는 펴고,\n여러 장은 나누고, 글자까지 읽어 드립니다.\n\n갤러리 사진은 왼쪽 아래 버튼으로 가져오세요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted, height: 1.6),
          ),
          const SizedBox(height: 40),
          const Text(kCopyright, style: TextStyle(color: Colors.white24, fontSize: 11)),
        ]),
      ),
    );
  }
}
