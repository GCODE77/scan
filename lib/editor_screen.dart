import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';
import 'crop_screen.dart';
import 'ocr.dart';
import 'scanner.dart';
import 'theme.dart';

/// 촬영 후 편집 화면: 필터 고르기, 회전, 자르기, 다시 찍기, 텍스트 추출.
/// [pages] 목록을 직접 고친다.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.pages, this.initial = 0});

  final List<ScanPage> pages;
  final int initial;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final _pager = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _busy = false;
  bool _compare = false;

  /// 필터 미리보기 썸네일 캐시 (편 이미지별)
  final _thumbs = Expando<Future<Map<ScanMode, Uint8List>>>();

  List<ScanPage> get _pages => widget.pages;
  ScanPage get _page => _pages[_index];

  Future<void> _work(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<ScanMode, Uint8List>> _thumbsFor(ScanPage p) => _thumbs[p.flat] ??= _makeThumbs(p.flat);

  static Future<Map<ScanMode, Uint8List>> _makeThumbs(Uint8List flat) async => {
        for (final m in ScanMode.values) m: await compute(renderPage, (flat, m, 0, 240)),
      };

  void _setFilter(ScanMode m, {bool all = false}) => _work(() async {
        for (final p in all ? _pages : [_page]) {
          if (p.mode == m) continue;
          p.mode = m;
          await p.render();
        }
      });

  void _rotate() => _work(() async {
        _page.quarterTurns -= 1; // 왼쪽(반시계)으로 90도
        await _page.render();
      });

  /// 같은 사진에서 나온 페이지들(양면이면 2장)의 위치
  List<int> _group(ScanPage p) =>
      [for (var i = 0; i < _pages.length; i++) if (identical(_pages[i].det, p.det)) i];

  /// 같은 사진의 페이지들을 새 페이지들로 바꾼다 (필터·회전은 유지)
  Future<void> _replaceGroup(ScanPage old, List<ScanPage> fresh) async {
    final idx = _group(old);
    for (final p in fresh) {
      p.mode = old.mode;
      p.quarterTurns = old.quarterTurns;
      await p.render();
    }
    setState(() {
      for (final i in idx.reversed) {
        _pages.removeAt(i);
      }
      _pages.insertAll(idx.first, fresh);
      _index = idx.first + (old.part).clamp(0, fresh.length - 1);
    });
    _pager.jumpToPage(_index);
  }

  Future<void> _crop() async {
    final p = _page;
    final shape = await Navigator.push<PageShape>(context,
        MaterialPageRoute(builder: (_) => CropScreen(detection: p.det, initial: p.shape)));
    if (shape == null) return;
    await _work(() async {
      final flats = await compute(warpFlat, (p.det.jpg, shape));
      await _replaceGroup(p, [
        for (var i = 0; i < flats.length; i++) ScanPage(det: p.det, shape: shape, part: i, flat: flats[i]),
      ]);
    });
  }

  Future<void> _retake() async {
    final p = _page;
    final fresh = await Navigator.push<List<ScanPage>>(
        context, MaterialPageRoute(builder: (_) => const CameraScreen()));
    if (fresh == null || fresh.isEmpty) return;
    await _work(() => _replaceGroup(p, fresh));
  }

  void _delete() {
    setState(() {
      _pages.removeAt(_index);
      if (_index >= _pages.length) _index = _pages.length - 1;
    });
    if (_pages.isEmpty) Navigator.pop(context);
  }

  Future<void> _extractText() async {
    final p = _page;
    if (p.ocr == null) {
      await _work(() async => p.ocr = await Ocr.recognize(p.jpg));
    }
    if (!mounted) return;
    final text = p.ocr!.text;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scroll) => Column(children: [
          ListTile(
            title: const Text('텍스트 추출 (한국어·영어)'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('복사'),
              onPressed: text.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      Navigator.pop(sheet);
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('복사했습니다')));
                    },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(20),
              child: SelectableText(text.isEmpty ? '인식된 글자가 없습니다' : text,
                  style: const TextStyle(fontSize: 16, height: 1.6)),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) return const SizedBox();
    const bg = AppColors.bg;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        title: Text('편집 · ${_index + 1}/${_pages.length}'),
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            PageView.builder(
              controller: _pager,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Center(
                  child: Stack(children: [
                    Image.memory(
                        _compare && i == _index ? _pages[i].flat : _pages[i].jpg,
                        gaplessPlayback: true),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Material(
                        color: Colors.black45,
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.white),
                          onPressed: _delete,
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            // 인식된 영역: 원본 사진 위 윤곽선. 누르면 바로 수정
            Positioned(
              left: 12,
              bottom: 8,
              child: _OutlinePreview(page: _page, onTap: _busy ? null : _crop),
            ),
            if (_busy) const Center(child: CircularProgressIndicator()),
          ]),
        ),
        // 페이지 번호 + 비교 (누르고 있는 동안 원본 보기)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left, color: Colors.white),
              onPressed: _index == 0
                  ? null
                  : () => _pager.previousPage(
                      duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            ),
            Text('${_index + 1}/${_pages.length}', style: const TextStyle(color: Colors.white)),
            IconButton(
              icon: const Icon(Icons.chevron_right, color: Colors.white),
              onPressed: _index == _pages.length - 1
                  ? null
                  : () => _pager.nextPage(
                      duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            ),
            const Spacer(),
            GestureDetector(
              onTapDown: (_) => setState(() => _compare = true),
              onTapUp: (_) => setState(() => _compare = false),
              onTapCancel: () => setState(() => _compare = false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                child: const Row(children: [
                  Icon(Icons.compare, color: Colors.white, size: 18),
                  SizedBox(width: 6),
                  Text('비교', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ),
          ]),
        ),
        // 필터 줄
        SizedBox(
          height: 104,
          child: FutureBuilder(
            future: _thumbsFor(_page),
            builder: (context, snap) => ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final m in ScanMode.values)
                  GestureDetector(
                    onTap: _busy
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            _setFilter(m);
                          },
                    onLongPress: _busy ? null : () => _filterAllDialog(m),
                    child: Container(
                      width: 84,
                      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: _page.mode == m ? AppColors.accent : Colors.transparent,
                            width: 2.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(fit: StackFit.expand, children: [
                          if (snap.data != null)
                            Image.memory(snap.data![m]!, fit: BoxFit.cover, gaplessPlayback: true)
                          else
                            const ColoredBox(color: Colors.white10),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: double.infinity,
                              color: _page.mode == m ? AppColors.accent.withValues(alpha: .85) : Colors.black54,
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(scanModeLabels[m]!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 도구 모음
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(children: [
              _Tool(Icons.camera_alt_outlined, '다시 찍기', _busy ? null : _retake),
              _Tool(Icons.rotate_left, '왼쪽', _busy ? null : _rotate),
              _Tool(Icons.crop, '사진 자르기', _busy ? null : _crop),
              _Tool(Icons.text_fields, '텍스트 추출', _busy ? null : _extractText),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    minimumSize: const Size(84, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_rounded, size: 22),
                  SizedBox(width: 4),
                  Text('완료', style: TextStyle(fontWeight: FontWeight.w800)),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  void _filterAllDialog(ScanMode m) => showDialog(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('\'${scanModeLabels[m]}\' 필터'),
          content: const Text('모든 페이지에 적용할까요?'),
          actions: [
            TextButton(
                onPressed: () {
                  Navigator.pop(d);
                  _setFilter(m);
                },
                child: const Text('이 페이지만')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(d);
                  _setFilter(m, all: true);
                },
                child: const Text('모든 페이지')),
          ],
        ),
      );
}

class _Tool extends StatelessWidget {
  const _Tool(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// 원본 사진에 자동 인식된 윤곽(모서리·굴곡)을 그려 보여 주는 작은 창.
class _OutlinePreview extends StatelessWidget {
  const _OutlinePreview({required this.page, this.onTap});

  final ScanPage page;
  final VoidCallback? onTap;

  /// 원본 사진은 파일에서 읽을 수도 있어서 한 번만 읽어 둔다
  static final _cache = Expando<Uint8List>();

  @override
  Widget build(BuildContext context) {
    final d = page.det;
    final jpg = _cache[d] ??= d.jpg;
    const maxW = 92.0, maxH = 120.0;
    final s = (maxW / d.width).clamp(0.0, maxH / d.height);
    final w = d.width * s, h = d.height * s;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: w,
          height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white38),
            boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 10)],
          ),
          child: Stack(fit: StackFit.expand, children: [
            Image.memory(jpg, fit: BoxFit.fill, cacheWidth: 240, gaplessPlayback: true),
            CustomPaint(painter: _OutlinePainter(page.shape, s, page.shape.spread ? page.part : null)),
          ]),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.crop_rounded, size: 12, color: AppColors.accent),
            SizedBox(width: 4),
            Text('윤곽 수정', style: TextStyle(color: Colors.white, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }
}

class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.shape, this.scale, this.part);

  final PageShape shape;
  final double scale;

  /// 양면이면 이 페이지 쪽만 진하게
  final int? part;

  @override
  void paint(Canvas canvas, Size size) {
    Offset sc(Offset p) => p * scale;
    final t = sampleCurve(shape.top).map(sc).toList(), b = sampleCurve(shape.bottom).map(sc).toList();
    final outline = Path()..addPolygon([...t, ...b.reversed], true);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), outline),
      Paint()..color = Colors.black45,
    );
    canvas.drawPath(
      outline,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    if (shape.spread) {
      canvas.drawLine(sc(shape.top[kMid]), sc(shape.bottom[kMid]),
          Paint()
            ..color = Colors.orangeAccent
            ..strokeWidth = 1.4);
    }
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => old.shape != shape || old.scale != scale;
}
