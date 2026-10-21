import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'scanner.dart';

/// 검출된 윤곽(모서리 + 굴곡)을 손으로 조정하고, 색 처리 방식을 고른 뒤 페이지를 완성하는 화면.
/// 결과: 완성된 페이지 JPG 목록 (양면이면 2장).
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.detection});

  final Detection detection;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late PageShape _shape = widget.detection.shape.copy();
  ScanMode _mode = ScanMode.enhanced;
  int? _dragging; // 0~4: 위 가장자리, 5~9: 아래 가장자리
  bool _busy = false;

  Offset _point(int i) => i < 5 ? _shape.top[i] : _shape.bottom[i - 5];

  void _setPoint(int i, Offset p) => i < 5 ? _shape.top[i] = p : _shape.bottom[i - 5] = p;

  Future<void> _done() async {
    setState(() => _busy = true);
    final out = await compute(warpPage, (widget.detection.jpg, _shape, _mode));
    if (mounted) Navigator.pop<List<Uint8List>>(context, out);
  }

  /// 굴곡을 없애고 네 모서리 사이를 곧은 선으로
  void _straighten() => setState(() => _shape = PageShape.quad(
      [_shape.top.first, _shape.top.last, _shape.bottom.last, _shape.bottom.first], _shape.spread));

  @override
  Widget build(BuildContext context) {
    final d = widget.detection;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(d.found ? '윤곽 확인' : '모서리를 맞춰 주세요'),
        actions: [
          IconButton(
            tooltip: '곧게 (굴곡 없애기)',
            icon: const Icon(Icons.straighten),
            onPressed: _straighten,
          ),
          IconButton(
            tooltip: '전체 선택',
            icon: const Icon(Icons.fullscreen),
            onPressed: () => setState(() => _shape = PageShape.quad([
                  Offset.zero,
                  Offset(d.width.toDouble(), 0),
                  Offset(d.width.toDouble(), d.height.toDouble()),
                  Offset(0, d.height.toDouble()),
                ], _shape.spread)),
          ),
          IconButton(
            tooltip: '자동 검출로 되돌리기',
            icon: const Icon(Icons.auto_fix_high),
            onPressed: () => setState(() => _shape = d.shape.copy(spread: _shape.spread)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: LayoutBuilder(builder: (context, box) {
                final s = (box.maxWidth / d.width).clamp(0.0, box.maxHeight / d.height);
                final ox = (box.maxWidth - d.width * s) / 2;
                final oy = (box.maxHeight - d.height * s) / 2;
                Offset toScreen(Offset p) => Offset(ox + p.dx * s, oy + p.dy * s);
                Offset toImage(Offset p) => Offset(
                      ((p.dx - ox) / s).clamp(0, d.width.toDouble()),
                      ((p.dy - oy) / s).clamp(0, d.height.toDouble()),
                    );
                final top = _shape.top.map(toScreen).toList();
                final bottom = _shape.bottom.map(toScreen).toList();
                final handles = [...top, ...bottom];

                return GestureDetector(
                  onPanStart: (e) {
                    // 손가락에서 가장 가까운 조절점을 잡는다
                    var best = 0;
                    for (var i = 1; i < handles.length; i++) {
                      if ((handles[i] - e.localPosition).distance <
                          (handles[best] - e.localPosition).distance) {
                        best = i;
                      }
                    }
                    if ((handles[best] - e.localPosition).distance < 50) _dragging = best;
                  },
                  onPanUpdate: (e) {
                    final i = _dragging;
                    if (i == null) return;
                    setState(() => _setPoint(i, toImage(e.localPosition)));
                  },
                  onPanEnd: (_) => setState(() => _dragging = null),
                  child: Stack(children: [
                    Positioned(
                      left: ox,
                      top: oy,
                      width: d.width * s,
                      height: d.height * s,
                      child: Image.memory(d.jpg, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                          painter: _ShapePainter(top, bottom, _shape.spread, _dragging)),
                    ),
                    if (_dragging != null)
                      _Magnifier(
                          image: d.jpg, d: d, at: _point(_dragging!), screen: handles[_dragging!], box: box),
                  ]),
                );
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('한 쪽'), icon: Icon(Icons.description)),
                  ButtonSegment(value: true, label: Text('양면'), icon: Icon(Icons.menu_book)),
                ],
                selected: {_shape.spread},
                onSelectionChanged: (v) => setState(() => _shape = _shape.copy(spread: v.first)),
                style: const ButtonStyle(
                    foregroundColor: WidgetStatePropertyAll(Colors.white),
                    visualDensity: VisualDensity.compact),
              ),
              const Spacer(),
              Text(_shape.spread ? '가운데 점 = 제본선' : '파란 점을 끌어 굴곡 맞춤',
                  style: const TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final m in ScanMode.values)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ChoiceChip(
                      label: Text(scanModeLabels[m]!),
                      selected: _mode == m,
                      onSelected: (_) => setState(() => _mode = m),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _busy ? null : _done,
                icon: _busy
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_shape.spread ? '펴서 2페이지 추가' : '펴서 페이지 추가'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.top, this.bottom, this.spread, this.active);

  final List<Offset> top, bottom;
  final bool spread;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final t = sampleCurve(top), b = sampleCurve(bottom);
    final path = Path()..addPolygon([...t, ...b.reversed], true);
    // 페이지 바깥은 어둡게
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), path),
      Paint()..color = Colors.black54,
    );
    final line = Paint()
      ..color = Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawPath(path, line);
    // 펴질 모양을 짐작할 수 있게 가로 안내선
    final guide = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var v = 0.25; v < 1; v += 0.25) {
      canvas.drawPoints(
          PointMode.polygon, [for (var i = 0; i < t.length; i++) Offset.lerp(t[i], b[i], v)!], guide);
    }
    if (spread) {
      canvas.drawLine(top[2], bottom[2], line..color = Colors.orangeAccent);
    }
    final pts = [...top, ...bottom];
    for (var i = 0; i < pts.length; i++) {
      final corner = i == 0 || i == 4 || i == 5 || i == 9;
      final spine = spread && (i == 2 || i == 7);
      final r = i == active ? 15.0 : (corner ? 12.0 : 9.0);
      canvas.drawCircle(pts[i], r, Paint()..color = Colors.white);
      canvas.drawCircle(
          pts[i],
          r - 3,
          Paint()
            ..color = spine
                ? Colors.orangeAccent
                : corner
                    ? Colors.lightBlueAccent
                    : Colors.lightBlue.shade200);
    }
  }

  @override
  bool shouldRepaint(_ShapePainter old) => true;
}

/// 조절점을 끌 때 손가락에 가려지는 부분을 확대해서 보여준다.
class _Magnifier extends StatelessWidget {
  const _Magnifier(
      {required this.image, required this.d, required this.at, required this.screen, required this.box});

  final Uint8List image;
  final Detection d;
  final Offset at;
  final Offset screen;
  final BoxConstraints box;

  @override
  Widget build(BuildContext context) {
    const size = 120.0; // 원본 해상도 1:1 (화면보다 훨씬 크게 보임)
    // 손가락 반대쪽 위 모서리에 표시
    final left = screen.dx < box.maxWidth / 2 ? box.maxWidth - size : 0.0;
    return Positioned(
      left: left,
      top: 0,
      width: size,
      height: size,
      child: ClipOval(
        child: Container(
          color: Colors.black,
          child: Stack(children: [
            Positioned(
              left: size / 2 - at.dx,
              top: size / 2 - at.dy,
              width: d.width.toDouble(),
              height: d.height.toDouble(),
              child: Image.memory(image, fit: BoxFit.fill, gaplessPlayback: true),
            ),
            const Center(child: Icon(Icons.add, color: Colors.redAccent, size: 28)),
          ]),
        ),
      ),
    );
  }
}
