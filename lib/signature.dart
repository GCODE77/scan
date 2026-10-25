import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'theme.dart';

/// 페이지 위에 얹는 서명 (투명 배경 PNG).
/// [rect]는 페이지 이미지 기준 0~1 비율, [turns]는 서명 그림 자체의 회전(90도 단위).
class Stamp {
  Stamp(this.png, this.rect, {this.turns = 0});

  final Uint8List png;
  Rect rect;
  int turns;
}

const _inkColors = [Color(0xFF111111), Color(0xFF1A3FB5), Color(0xFFC62828)];

/// 서명 글씨체: (글꼴 이름, 화면 표시 이름). null = 기본 고딕
const _fonts = <(String?, String)>[
  ('NanumPen', '펜글씨'),
  ('NanumBrush', '붓글씨'),
  ('Gaegu', '손글씨'),
  ('Dokdo', '개성체'),
  (null, '고딕'),
];

/// 서명 만들기: 직접 그리기 / 글자로 입력. 결과는 투명 PNG.
Future<Uint8List?> makeSignature(BuildContext context) => Navigator.push<Uint8List>(
    context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _SignatureMaker()));

/// 마지막으로 쓴 서명 (다음에 바로 다시 쓰기)
Future<File> _lastFile() async => File('${(await getApplicationSupportDirectory()).path}/last_signature.png');

class _SignatureMaker extends StatefulWidget {
  const _SignatureMaker();

  @override
  State<_SignatureMaker> createState() => _SignatureMakerState();
}

class _SignatureMakerState extends State<_SignatureMaker> {
  int _tab = 0; // 0 그리기, 1 글자
  Color _color = _inkColors.first;
  final List<List<Offset>> _strokes = [];
  final _text = TextEditingController();
  bool _italic = false;
  int _font = 0;

  /// 굵기: 그리기는 선 두께(px), 글자는 테두리를 덧대는 두께
  double _thick = 4;
  Uint8List? _last;

  @override
  void initState() {
    super.initState();
    _lastFile().then((f) async {
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (mounted) setState(() => _last = b);
      }
    });
  }

  Future<void> _done() async {
    final png = _tab == 0 ? await _renderStrokes() : await _renderText();
    if (png == null) return;
    (await _lastFile()).writeAsBytes(png).ignore();
    if (mounted) Navigator.pop(context, png);
  }

  /// 그린 획만 감싸도록 잘라서 투명 PNG로 (3배 해상도)
  Future<Uint8List?> _renderStrokes() async {
    final pts = _strokes.expand((s) => s).toList();
    if (pts.isEmpty) return null;
    var l = pts.first.dx, t = pts.first.dy, r = l, b = t;
    for (final p in pts) {
      l = p.dx < l ? p.dx : l;
      t = p.dy < t ? p.dy : t;
      r = p.dx > r ? p.dx : r;
      b = p.dy > b ? p.dy : b;
    }
    const pad = 12.0, sc = 3.0;
    final w = (r - l + pad * 2), h = (b - t + pad * 2);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(sc);
    canvas.translate(pad - l, pad - t);
    _paintStrokes(canvas, _strokes, _color, _thick);
    final img = await rec.endRecording().toImage((w * sc).ceil(), (h * sc).ceil());
    return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  Future<Uint8List?> _renderText() async {
    final text = _text.text.trim();
    if (text.isEmpty) return null;
    final tp = TextPainter(
      text: TextSpan(text: text, style: _textStyle(140)),
      textDirection: TextDirection.ltr,
    )..layout();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const pad = 30.0;
    if (_thick > 4) {
      (TextPainter(
        text: TextSpan(text: text, style: _textStyle(140, stroke: true)),
        textDirection: TextDirection.ltr,
      )..layout())
          .paint(canvas, const Offset(pad, pad / 2));
    }
    tp.paint(canvas, const Offset(pad, pad / 2));
    final img = await rec.endRecording().toImage((tp.width + pad * 2).ceil(), (tp.height + pad).ceil());
    return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  /// 글자 서명 모양. [stroke]가 true면 같은 글자를 굵기만큼 테두리로 덧그리는 용도.
  TextStyle _textStyle(double size, {bool stroke = false}) {
    final base = TextStyle(
      fontFamily: _fonts[_font].$1,
      fontSize: size,
      fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
      fontWeight: _fonts[_font].$1 == null ? FontWeight.w600 : FontWeight.normal,
      letterSpacing: -size * 0.01,
    );
    // 굵기 4가 기본(덧그리지 않음). 그보다 크면 테두리를 덧대 두껍게
    final extra = (_thick - 4) * size / 60;
    if (stroke) {
      return base.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = extra.clamp(0, 999)
            ..strokeJoin = StrokeJoin.round
            ..color = _color);
    }
    return base.copyWith(color: _color);
  }

  /// 굵기를 반영해 글자 그리기 (테두리 + 채움)
  Widget _styledText(String text, double size, {Color? color}) {
    final fill = _textStyle(size).copyWith(color: color ?? _color);
    if (_thick <= 4 || color != null) return Text(text, style: fill);
    return Stack(children: [
      Text(text, style: _textStyle(size, stroke: true)),
      Text(text, style: fill),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final canDone = _tab == 0 ? _strokes.isNotEmpty : _text.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('서명 만들기'),
        actions: [
          if (_last != null)
            TextButton.icon(
              onPressed: () => Navigator.pop(context, _last),
              icon: const Icon(Icons.history_rounded),
              label: const Text('지난 서명'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, icon: Icon(Icons.draw_rounded), label: Text('직접 그리기')),
              ButtonSegment(value: 1, icon: Icon(Icons.keyboard_rounded), label: Text('글자로 입력')),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              clipBehavior: Clip.antiAlias,
              child: _tab == 0 ? _drawPad() : _textPad(),
            ),
          ),
          const SizedBox(height: 14),
          Row(children: [
            for (final c in _inkColors)
              GestureDetector(
                onTap: () => setState(() => _color = c),
                child: Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(color: _color == c ? AppColors.accent : Colors.white24, width: 3),
                  ),
                ),
              ),
            const Spacer(),
            if (_tab == 0)
              TextButton.icon(
                onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('지우기'),
              )
            else
              FilterChip(
                label: const Text('기울임'),
                selected: _italic,
                onSelected: (v) => setState(() => _italic = v),
              ),
          ]),
          Row(children: [
            const Icon(Icons.line_weight_rounded, size: 20, color: Colors.white70),
            const SizedBox(width: 8),
            const Text('굵기', style: TextStyle(color: Colors.white70)),
            Expanded(
              child: Slider(
                value: _thick,
                min: 2,
                max: 12,
                divisions: 10,
                label: _thick.round().toString(),
                onChanged: (v) => setState(() => _thick = v),
              ),
            ),
          ]),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canDone ? _done : null,
              icon: const Icon(Icons.check_rounded),
              label: const Text('다음: 위치·크기 정하기'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _drawPad() => Stack(children: [
        const Center(
          child: Text('여기에 손가락으로 서명하세요', style: TextStyle(color: Colors.black26, fontSize: 16)),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 60,
          child: Container(height: 1.5, color: Colors.black12),
        ),
        GestureDetector(
          onPanStart: (e) => setState(() => _strokes.add([e.localPosition])),
          onPanUpdate: (e) => setState(() => _strokes.last.add(e.localPosition)),
          child: CustomPaint(painter: _StrokePainter(_strokes, _color, _thick), size: Size.infinite),
        ),
      ]);

  Widget _textPad() => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextField(
            controller: _text,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black87, fontSize: 18),
            decoration: const InputDecoration(
              hintText: '이름을 입력하세요',
              filled: true,
              fillColor: Color(0xFFF2F3F5),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          // 글씨체 고르기 (각 버튼이 그 글씨체로 보인다)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < _fonts.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_fonts[i].$2,
                        style: TextStyle(fontFamily: _fonts[i].$1, fontSize: 17, color: Colors.black87)),
                    selected: _font == i,
                    selectedColor: const Color(0xFFBDF5E6),
                    backgroundColor: const Color(0xFFF2F3F5),
                    onSelected: (_) => setState(() => _font = i),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 20),
          FittedBox(
            child: _styledText(_text.text.isEmpty ? '홍길동' : _text.text, 64,
                color: _text.text.isEmpty ? Colors.black12 : null),
          ),
        ]),
      );
}

void _paintStrokes(Canvas canvas, List<List<Offset>> strokes, Color color, double width) {
  final paint = Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  for (final s in strokes) {
    if (s.length == 1) {
      canvas.drawCircle(s.first, width / 2, paint..style = PaintingStyle.fill);
      paint.style = PaintingStyle.stroke;
      continue;
    }
    // 부드러운 곡선 (중간점을 잇는 2차 곡선)
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (var i = 1; i < s.length - 1; i++) {
      final m = (s[i] + s[i + 1]) / 2;
      path.quadraticBezierTo(s[i].dx, s[i].dy, m.dx, m.dy);
    }
    path.lineTo(s.last.dx, s.last.dy);
    canvas.drawPath(path, paint);
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes, this.color, this.width);

  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) => _paintStrokes(canvas, strokes, color, width);

  @override
  bool shouldRepaint(_StrokePainter old) => true;
}

/// 서명 위치·크기 정하기: 끌어서 옮기고, 오른쪽 아래 손잡이로 크기 조절.
/// 결과: 페이지 기준 0~1 비율의 사각형.
Future<Rect?> placeSignature(BuildContext context, Uint8List pageJpg, Size pageSize, Uint8List png) =>
    Navigator.push<Rect>(
        context,
        MaterialPageRoute(
            fullscreenDialog: true, builder: (_) => _PlaceScreen(page: pageJpg, pageSize: pageSize, png: png)));

class _PlaceScreen extends StatefulWidget {
  const _PlaceScreen({required this.page, required this.pageSize, required this.png});

  final Uint8List page;
  final Size pageSize;
  final Uint8List png;

  @override
  State<_PlaceScreen> createState() => _PlaceScreenState();
}

class _PlaceScreenState extends State<_PlaceScreen> {
  double? _aspect; // 서명 그림 가로/세로
  Rect? _r; // 0~1 비율

  @override
  void initState() {
    super.initState();
    ui.instantiateImageCodec(widget.png).then((c) => c.getNextFrame()).then((f) {
      final a = f.image.width / f.image.height;
      final pageA = widget.pageSize.width / widget.pageSize.height;
      const w = 0.35;
      final h = w * pageA / a;
      setState(() {
        _aspect = a;
        _r = Rect.fromLTWH(0.6 - w / 2, 0.85 - h / 2, w, h); // 기본: 오른쪽 아래
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ps = widget.pageSize;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('서명 넣기'),
          Text('끌어서 옮기고, 모서리 손잡이로 크기 조절', style: TextStyle(fontSize: 12, color: Colors.white60)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(builder: (context, box) {
              final s = (box.maxWidth / ps.width).clamp(0.0, box.maxHeight / ps.height);
              final w = ps.width * s, h = ps.height * s;
              final r = _r;
              return Center(
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(child: Image.memory(widget.page, fit: BoxFit.fill)),
                    if (r != null) ...[
                      Positioned(
                        left: r.left * w,
                        top: r.top * h,
                        width: r.width * w,
                        height: r.height * h,
                        child: GestureDetector(
                          onPanUpdate: (e) => setState(() {
                            final nl = (r.left + e.delta.dx / w).clamp(0.0, 1 - r.width);
                            final nt = (r.top + e.delta.dy / h).clamp(0.0, 1 - r.height);
                            _r = Rect.fromLTWH(nl, nt, r.width, r.height);
                          }),
                          child: Container(
                            decoration: BoxDecoration(
                                border: Border.all(color: AppColors.accent, width: 1.5)),
                            child: Image.memory(widget.png, fit: BoxFit.fill),
                          ),
                        ),
                      ),
                      // 크기 조절 손잡이 (비율 유지)
                      Positioned(
                        left: r.right * w - 16,
                        top: r.bottom * h - 16,
                        child: GestureDetector(
                          onPanUpdate: (e) => setState(() {
                            final pageA = ps.width / ps.height;
                            final nw = (r.width + e.delta.dx / w).clamp(0.08, 1 - r.left);
                            final nh = nw * pageA / _aspect!;
                            if (r.top + nh > 1) return;
                            _r = Rect.fromLTWH(r.left, r.top, nw, nh);
                          }),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                            child: const Icon(Icons.open_in_full_rounded, size: 18, color: Color(0xFF00281F)),
                          ),
                        ),
                      ),
                    ],
                  ]),
                ),
              );
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _r == null ? null : () => Navigator.pop(context, _r),
              icon: const Icon(Icons.check_rounded),
              label: const Text('이 위치에 넣기'),
            ),
          ),
        ),
      ]),
    );
  }
}
