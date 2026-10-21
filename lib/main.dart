import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'camera_screen.dart';
import 'editor_screen.dart';
import 'ocr.dart';
import 'pages.dart';

void main() => runApp(const BookScanApp());

class BookScanApp extends StatelessWidget {
  const BookScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '북스캔',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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

  /// 저장 대상: 선택한 페이지가 있으면 그것만, 없으면 전체
  List<ScanPage> get _targets =>
      _selected.isEmpty ? _pages : _pages.where(_selected.contains).toList();

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

  /// 검색 가능한 PDF: 페이지 사진 위에 OCR 글자를 보이지 않게 겹쳐 넣는다.
  /// 그래서 PDF 뷰어에서 검색·복사·선택이 된다.
  Future<File> _writePdf() async {
    final font = pw.Font.ttf(await rootBundle.load('assets/fonts/NanumGothic-Regular.ttf'));
    final doc = pw.Document(title: '북스캔');
    for (final p in _targets) {
      final img = pw.MemoryImage(p.jpg);
      // 페이지 크기를 사진 비율 그대로 (A4 폭 기준)
      final w = PdfPageFormat.a4.width;
      final s = w / img.width!;
      final h = img.height! * s;
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Stack(children: [
          pw.Positioned.fill(child: pw.Image(img, fit: pw.BoxFit.fill)),
          for (final l in p.ocr?.lines ?? <OcrLine>[])
            if (l.box.width > 0 && l.box.height > 0)
              pw.Positioned(
                left: l.box.left * s,
                top: l.box.top * s,
                child: pw.SizedBox(
                  width: l.box.width * s,
                  height: l.box.height * s,
                  child: pw.FittedBox(
                    fit: pw.BoxFit.fill,
                    child: pw.Text(l.text,
                        style: pw.TextStyle(
                            font: font, fontSize: 10, renderingMode: PdfTextRenderingMode.invisible)),
                  ),
                ),
              ),
        ]),
      ));
    }
    return _saveFile('pdf', await doc.save());
  }

  Future<File> _saveFile(String ext, List<int> bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    return File('${dir.path}/scan_$stamp.$ext').writeAsBytes(bytes);
  }

  String get _allText => [
        for (var i = 0; i < _pages.length; i++) '── ${i + 1}페이지 ──\n${_pages[i].ocr?.text ?? ''}',
      ].join('\n\n');

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      if (_targets.any((p) => p.ocr == null)) {
        setState(() => _busyText = '글자 인식 마무리 중…');
        await _ocrQueue;
      }
      setState(() => _busyText = null);
      await job();
      if (mounted && done.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('실패: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _exportPdf() => _run(() async {
        final f = await _writePdf();
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: '스캔 PDF'));
      }, '');

  void _exportText() => _run(() async {
        // BOM을 붙여야 윈도우 메모장에서도 한글이 깨지지 않는다
        final f = await _saveFile('txt', [0xEF, 0xBB, 0xBF, ...utf8.encode(_allText)]);
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: '스캔 텍스트'));
      }, '');

  void _saveImages() => _run(() async {
        if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
        for (final p in _targets) {
          await Gal.putImageBytes(p.jpg, album: 'BookScan');
        }
      }, '사진 ${_targets.length}장을 갤러리(BookScan)에 저장했습니다');

  @override
  Widget build(BuildContext context) {
    final pending = _pages.where((p) => p.ocr == null).length;
    final selecting = _selected.isNotEmpty;
    final what = selecting ? '선택한 ${_selected.length}페이지' : '전체 ${_pages.length}페이지';
    return Scaffold(
      appBar: AppBar(
        leading: selecting
            ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear))
            : null,
        title: Text(selecting
            ? '${_selected.length}개 선택'
            : _pages.isEmpty
                ? '북스캔'
                : '북스캔 · ${_pages.length}페이지'),
        actions: [
          if (selecting) ...[
            IconButton(
              tooltip: '모두 선택',
              icon: const Icon(Icons.select_all),
              onPressed: () => setState(() => _selected.addAll(_pages)),
            ),
            IconButton(
              tooltip: '삭제',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() {
                _pages.removeWhere(_selected.contains);
                _selected.clear();
              }),
            ),
          ],
          if (_pages.isNotEmpty)
            PopupMenuButton<void Function()>(
              enabled: !_busy,
              icon: const Icon(Icons.save_alt),
              tooltip: '저장',
              onSelected: (f) => f(),
              itemBuilder: (_) => [
                PopupMenuItem(enabled: false, child: Text('$what 저장')),
                PopupMenuItem(
                    value: _exportPdf,
                    child: const ListTile(
                        leading: Icon(Icons.picture_as_pdf),
                        title: Text('PDF'),
                        subtitle: Text('글자 검색·복사 가능'))),
                PopupMenuItem(
                    value: _saveImages,
                    child: const ListTile(
                        leading: Icon(Icons.photo_library),
                        title: Text('사진 (JPG)'),
                        subtitle: Text('갤러리 BookScan 앨범'))),
                PopupMenuItem(
                    value: _exportText,
                    child: const ListTile(
                        leading: Icon(Icons.text_snippet), title: Text('텍스트 (.txt)'))),
              ],
            ),
        ],
        bottom: pending == 0
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(24),
                child: Text('글자 인식 중… ($pending페이지 남음)',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
      ),
      body: Stack(children: [
        _pages.isEmpty
            ? const Center(
                child: Text('아래 버튼을 눌러 책을 스캔하세요',
                    style: TextStyle(fontSize: 16, color: Colors.grey)))
            : PageGrid(
                pages: _pages,
                selected: _selected,
                onTap: (i) => selecting ? _toggle(i) : _edit(i),
                onLongPress: _toggle,
              ),
        if (_busy)
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              if (_busyText != null) ...[const SizedBox(height: 12), Text(_busyText!)],
            ]),
          ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _scan,
        icon: const Icon(Icons.document_scanner),
        label: const Text('스캔'),
      ),
    );
  }
}
