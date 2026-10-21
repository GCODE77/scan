import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'camera_screen.dart';
import 'crop_screen.dart';
import 'scanner.dart';

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
  final List<Uint8List> _pages = [];
  bool _busy = false;

  /// 촬영 → 모서리 검출 → 조정 화면 → 페이지 추가. 연속 촬영을 위해 반복한다.
  Future<void> _scan() async {
    final nav = Navigator.of(context);
    while (mounted) {
      final path = await nav.push<String>(MaterialPageRoute(builder: (_) => const CameraScreen()));
      if (path == null || !mounted) return;

      setState(() => _busy = true);
      final det = await compute(detectPage, path);
      File(path).delete().ignore();
      if (!mounted) return;
      setState(() => _busy = false);

      final pages = await nav.push<List<Uint8List>>(MaterialPageRoute(builder: (_) => CropScreen(detection: det)));
      if (pages == null) return;
      setState(() => _pages.addAll(pages));
    }
  }

  Future<File> _writePdf() async {
    final doc = pw.Document();
    for (final p in _pages) {
      final img = pw.MemoryImage(p);
      // 페이지 크기를 사진 비율 그대로 (A4 폭 기준)
      final w = PdfPageFormat.a4.width;
      final h = w * img.height! / img.width!;
      doc.addPage(pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
      ));
    }
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${dir.path}/scan_$stamp.pdf');
    return file.writeAsBytes(await doc.save());
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
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

  void _saveImages() => _run(() async {
        if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
        for (final p in _pages) {
          await Gal.putImageBytes(p, album: 'BookScan');
        }
      }, '사진 ${_pages.length}장을 갤러리(BookScan)에 저장했습니다');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_pages.isEmpty ? '북스캔' : '북스캔 · ${_pages.length}페이지'),
        actions: [
          if (_pages.isNotEmpty) ...[
            IconButton(tooltip: '사진으로 저장', icon: const Icon(Icons.photo_library), onPressed: _busy ? null : _saveImages),
            IconButton(tooltip: 'PDF로 저장/공유', icon: const Icon(Icons.picture_as_pdf), onPressed: _busy ? null : _exportPdf),
          ],
        ],
      ),
      body: Stack(children: [
        _pages.isEmpty
            ? const Center(
                child: Text('아래 버튼을 눌러 책을 스캔하세요',
                    style: TextStyle(fontSize: 16, color: Colors.grey)))
            : ReorderableGridHint(
                pages: _pages,
                onDelete: (i) => setState(() => _pages.removeAt(i)),
                onMove: (i, d) => setState(() {
                  final j = i + d;
                  if (j < 0 || j >= _pages.length) return;
                  final t = _pages[i];
                  _pages[i] = _pages[j];
                  _pages[j] = t;
                }),
              ),
        if (_busy) const Center(child: CircularProgressIndicator()),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _scan,
        icon: const Icon(Icons.document_scanner),
        label: const Text('스캔'),
      ),
    );
  }
}

/// 페이지 썸네일 목록. 길게 누르면 이동/삭제 메뉴.
class ReorderableGridHint extends StatelessWidget {
  const ReorderableGridHint(
      {super.key, required this.pages, required this.onDelete, required this.onMove});

  final List<Uint8List> pages;
  final void Function(int) onDelete;
  final void Function(int, int) onMove;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, childAspectRatio: 0.7, mainAxisSpacing: 10, crossAxisSpacing: 10),
      itemCount: pages.length,
      itemBuilder: (context, i) => GestureDetector(
        onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(title: Text('${i + 1}페이지')),
                      body: InteractiveViewer(
                          maxScale: 6, child: Center(child: Image.memory(pages[i]))),
                    ))),
        onLongPress: () => showModalBottomSheet(
          context: context,
          builder: (_) => SafeArea(
            child: Wrap(children: [
              ListTile(
                  leading: const Icon(Icons.arrow_back),
                  title: const Text('앞으로 이동'),
                  onTap: () {
                    Navigator.pop(context);
                    onMove(i, -1);
                  }),
              ListTile(
                  leading: const Icon(Icons.arrow_forward),
                  title: const Text('뒤로 이동'),
                  onTap: () {
                    Navigator.pop(context);
                    onMove(i, 1);
                  }),
              ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text('삭제'),
                  onTap: () {
                    Navigator.pop(context);
                    onDelete(i);
                  }),
            ]),
          ),
        ),
        child: Column(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
              child: Image.memory(pages[i], fit: BoxFit.cover, width: double.infinity, cacheWidth: 300),
            ),
          ),
          const SizedBox(height: 4),
          Text('${i + 1}'),
        ]),
      ),
    );
  }
}
