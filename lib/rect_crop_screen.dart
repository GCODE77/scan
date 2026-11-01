import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// 사각형 영역 자르기: 페이지에서 쓰고 싶은 부분(영수증·명함·사진 한 장 등)만 고른다.
/// 결과: (고른 영역 — 이미지 크기에 대한 0~1 비율, 복사본으로 추가할지). 취소하면 null.
class RectCropScreen extends StatefulWidget {
  const RectCropScreen({super.key, required this.image});

  final Uint8List image;

  @override
  State<RectCropScreen> createState() => _RectCropScreenState();
}

enum _Grip { tl, tr, bl, br, left, right, top, bottom, move }

/// 자주 쓰는 비율 (가로:세로). null이면 자유.
const _ratios = <(String, double?)>[
  ('자유', null),
  ('전체', 0),
  ('1:1', 1),
  ('4:3', 4 / 3),
  ('3:4', 3 / 4),
  ('A4 세로', 1 / 1.4142),
  ('A4 가로', 1.4142),
  ('명함', 9 / 5.5),
];

class _RectCropScreenState extends State<RectCropScreen> {
  Rect _r = const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9);
  Size? _px; // 이미지 픽셀 크기
  _Grip? _grip;
  double? _lock; // 모서리를 끌 때 지킬 가로:세로 비율

  static const _min = 0.05;

  @override
  void initState() {
    super.initState();
    decodeImageFromList(widget.image).then((img) {
      if (mounted) setState(() => _px = Size(img.width.toDouble(), img.height.toDouble()));
    });
  }

  /// 이미지 안에서 가로:세로가 [ratio]인 가장 큰 영역을 가운데에
  void _preset(double? ratio) {
    final px = _px;
    if (px == null) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (ratio == null) {
        _lock = null;
        return;
      }
      if (ratio == 0) {
        _r = const Rect.fromLTRB(0, 0, 1, 1);
        _lock = null;
        return;
      }
      // 이미지 가로세로비보다 넓으면 가로를 꽉 채우고, 아니면 세로를 꽉 채운다 (살짝 안쪽으로)
      var w = 0.92, h = 0.92;
      if (px.width / px.height > ratio) {
        w = h * ratio * px.height / px.width;
      } else {
        h = w * px.width / px.height / ratio;
      }
      _r = Rect.fromCenter(center: const Offset(0.5, 0.5), width: w, height: h);
      _lock = ratio;
    });
  }

  void _drag(Offset d) {
    final px = _px;
    if (px == null || _grip == null) return;
    var l = _r.left, t = _r.top, r = _r.right, b = _r.bottom;
    switch (_grip!) {
      case _Grip.move:
        final dx = d.dx.clamp(-l, 1 - r), dy = d.dy.clamp(-t, 1 - b);
        l += dx;
        r += dx;
        t += dy;
        b += dy;
      case _Grip.left:
        l = (l + d.dx).clamp(0.0, r - _min);
        _lock = null;
      case _Grip.right:
        r = (r + d.dx).clamp(l + _min, 1.0);
        _lock = null;
      case _Grip.top:
        t = (t + d.dy).clamp(0.0, b - _min);
        _lock = null;
      case _Grip.bottom:
        b = (b + d.dy).clamp(t + _min, 1.0);
        _lock = null;
      case _Grip.tl:
        l = (l + d.dx).clamp(0.0, r - _min);
        t = (t + d.dy).clamp(0.0, b - _min);
      case _Grip.tr:
        r = (r + d.dx).clamp(l + _min, 1.0);
        t = (t + d.dy).clamp(0.0, b - _min);
      case _Grip.bl:
        l = (l + d.dx).clamp(0.0, r - _min);
        b = (b + d.dy).clamp(t + _min, 1.0);
      case _Grip.br:
        r = (r + d.dx).clamp(l + _min, 1.0);
        b = (b + d.dy).clamp(t + _min, 1.0);
    }
    var next = Rect.fromLTRB(l, t, r, b);
    // 비율 고정: 가로를 기준으로 세로를 맞추고, 범위를 벗어나면 이번 움직임은 무시
    final lock = _lock;
    if (lock != null && const {_Grip.tl, _Grip.tr, _Grip.bl, _Grip.br}.contains(_grip)) {
      final hn = next.width * px.width / lock / px.height;
      final top = (_grip == _Grip.tl || _grip == _Grip.tr) ? next.bottom - hn : next.top;
      final bottom = (_grip == _Grip.tl || _grip == _Grip.tr) ? next.bottom : next.top + hn;
      if (top < 0 || bottom > 1 || hn < _min) return;
      next = Rect.fromLTRB(next.left, top, next.right, bottom);
    }
    setState(() => _r = next);
  }

  @override
  Widget build(BuildContext context) {
    final px = _px;
    final cropPx = px == null ? null : Size(_r.width * px.width, _r.height * px.height);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('영역 자르기'),
          Text(
              cropPx == null
                  ? '쓰고 싶은 부분만 사각형으로 고르세요'
                  : '${cropPx.width.round()} × ${cropPx.height.round()} px · 모서리·변을 끌어 조절',
              style: const TextStyle(fontSize: 12, color: Colors.white60)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: px == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, box) {
                    final s = (box.maxWidth / px.width).clamp(0.0, box.maxHeight / px.height);
                    final w = px.width * s, h = px.height * s;
                    final ox = (box.maxWidth - w) / 2, oy = (box.maxHeight - h) / 2;
                    // 영역(화면 좌표)과 손잡이 위치
                    final rect = Rect.fromLTRB(ox + _r.left * w, oy + _r.top * h, ox + _r.right * w, oy + _r.bottom * h);
                    final grips = <_Grip, Offset>{
                      _Grip.tl: rect.topLeft,
                      _Grip.tr: rect.topRight,
                      _Grip.bl: rect.bottomLeft,
                      _Grip.br: rect.bottomRight,
                      _Grip.left: rect.centerLeft,
                      _Grip.right: rect.centerRight,
                      _Grip.top: rect.topCenter,
                      _Grip.bottom: rect.bottomCenter,
                    };
                    return GestureDetector(
                      onPanStart: (e) {
                        _Grip? best;
                        var bd = 48.0; // 손가락 반경
                        for (final g in grips.entries) {
                          final dist = (g.value - e.localPosition).distance;
                          if (dist < bd) {
                            bd = dist;
                            best = g.key;
                          }
                        }
                        _grip = best ?? (rect.contains(e.localPosition) ? _Grip.move : null);
                      },
                      onPanUpdate: (e) => _drag(Offset(e.delta.dx / w, e.delta.dy / h)),
                      onPanEnd: (_) => _grip = null,
                      child: Stack(children: [
                        Positioned(
                          left: ox,
                          top: oy,
                          width: w,
                          height: h,
                          child: Image.memory(widget.image, fit: BoxFit.fill, gaplessPlayback: true),
                        ),
                        Positioned.fill(child: CustomPaint(painter: _CropPainter(rect, grips, _grip))),
                      ]),
                    );
                  }),
          ),
        ),
        // 비율 바로가기
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final (label, ratio) in _ratios)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ActionChip(
                    label: Text(label),
                    backgroundColor: ratio != null && ratio != 0 && _lock == ratio ? AppColors.accent.withValues(alpha: .25) : null,
                    onPressed: () => _preset(ratio),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: px == null ? null : () => Navigator.pop(context, (_r, true)),
                  icon: const Icon(Icons.control_point_duplicate_rounded),
                  label: const Text('복사본으로 추가'),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: px == null ? null : () => Navigator.pop(context, (_r, false)),
                  icon: const Icon(Icons.crop_rounded),
                  label: const Text('이 페이지 자르기'),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.rect, this.grips, this.active);

  final Rect rect;
  final Map<_Grip, Offset> grips;
  final _Grip? active;

  @override
  void paint(Canvas canvas, Size size) {
    // 바깥은 어둡게
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(rect)),
      Paint()..color = Colors.black54,
    );
    canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    // 삼등분선
    final thin = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(rect.left + rect.width * i / 3, rect.top), Offset(rect.left + rect.width * i / 3, rect.bottom), thin);
      canvas.drawLine(Offset(rect.left, rect.top + rect.height * i / 3), Offset(rect.right, rect.top + rect.height * i / 3), thin);
    }
    for (final g in grips.entries) {
      final corner = const {_Grip.tl, _Grip.tr, _Grip.bl, _Grip.br}.contains(g.key);
      final r = g.key == active ? 15.0 : (corner ? 12.0 : 9.0);
      canvas.drawCircle(g.value, r, Paint()..color = Colors.white);
      canvas.drawCircle(g.value, r - 3, Paint()..color = corner ? Colors.lightBlueAccent : Colors.lightBlue.shade200);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => true;
}
