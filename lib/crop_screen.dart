import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scanner.dart';

/// 사진 자르기: 자동 인식된 윤곽(모서리 + 굴곡)을 손으로 고치는 화면 (선택 기능).
/// 결과: 고친 윤곽.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.detection, this.initial});

  final Detection detection;
  final PageShape? initial;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late PageShape _shape = (widget.initial ?? widget.detection.shape).copy();
  late final Uint8List _jpg = widget.detection.jpg;
  int? _dragging; // 0~kPts-1: 위 가장자리, 그 다음: 아래 가장자리, 그 뒤: 왼쪽·오른쪽 변 가운데

  /// 왼쪽·오른쪽 변 가운데 손잡이 번호
  static const _leftMid = 2 * kPts, _rightMid = 2 * kPts + 1;

  Offset _sideMid(bool left) => Offset.lerp(
          left ? _shape.top.first : _shape.top.last, left ? _shape.bottom.first : _shape.bottom.last, 0.5)! +
      (left ? _shape.leftBow : _shape.rightBow);

  Offset _point(int i) => i == _leftMid
      ? _sideMid(true)
      : i == _rightMid
          ? _sideMid(false)
          : i < kPts
              ? _shape.top[i]
              : _shape.bottom[i - kPts];

  /// 손으로 잡을 수 있는 점: 모서리 4개 + 위·아래·왼쪽·오른쪽 변 가운데 4개 (나머지 점은 자동으로 따라온다)
  static const _visible = {0, kMid, kPts - 1, kPts, kPts + kMid, 2 * kPts - 1, _leftMid, _rightMid};

  /// 모서리 손잡이 번호 → 모서리 번호 (좌상 0, 우상 1, 우하 2, 좌하 3)
  static const _cornerOf = {0: 0, kPts - 1: 1, 2 * kPts - 1: 2, kPts: 3};

  /// 막 붙은 모서리 (잠깐 빛나는 표시)
  int? _snapped;
  int _snapSeq = 0;
  int _glowSeq = 0;

  /// 자석 켜기/끄기 (앱을 켜 있는 동안 기억)
  static bool _magnetOn = true;

  /// 끌기 시작한 위치 (원래 자리로 되끌려가지 않게)
  Offset? _dragFrom;

  /// 놓은 모서리를 근처의 실제 종이 모서리에 붙인다. 선들은 함께 따라온다.
  Future<void> _snap(int handle) async {
    final corner = _cornerOf[handle];
    if (corner == null) return;
    final seq = ++_snapSeq;
    final quad = [_shape.top.first, _shape.top.last, _shape.bottom.last, _shape.bottom.first];
    if (!_magnetOn) return;
    final drop = _point(handle), from = _dragFrom;
    final p = (await compute(snapCorners, (_jpg, quad, [corner])))[corner];
    // 그 사이 다른 점을 잡았으면 무시
    if (!mounted || p == null || seq != _snapSeq || _dragging != null) return;
    // 약한 자석: 놓은 곳 근처(대각선의 6%)에 모서리가 있을 때만 붙는다
    final diag = ((quad[2] - quad[0]).distance + (quad[3] - quad[1]).distance) / 2;
    if ((p - drop).distance > diag * 0.06) return;
    // 일부러 옮겼는데 원래 자리 쪽으로 되돌아가는 것이면 붙이지 않는다
    if (from != null && (p - from).distance < (drop - from).distance * 0.6) return;
    HapticFeedback.selectionClick();
    final glow = ++_glowSeq;
    setState(() {
      _setPoint(handle, p);
      _snapped = handle;
    });
    // 빛나는 표시는 잠깐 뒤 끈다 (변 자석을 기다리게 하지 않는다)
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted && glow == _glowSeq) setState(() => _snapped = null);
    });
  }

  /// 손잡이를 놓은 뒤 자석: 모서리는 종이 모서리에, 변은 종이 경계를 따라 붙는다.
  Future<void> _afterDrop(int handle) async {
    if (!_magnetOn) return;
    await _snap(handle);
    final corner = _cornerOf[handle];
    if (corner != null) {
      // 모서리를 옮기면 그 모서리에 닿은 두 변이 종이 테두리를 따라가게
      await _snapEdges({(corner + 3) % 4, corner});
    } else if (handle == _leftMid) {
      await _snapEdges({3});
    } else if (handle == _rightMid) {
      await _snapEdges({1});
    } else if (!_shape.spread) {
      // 양면일 때 위·아래 가운데 점은 제본선이라 변 자석을 쓰지 않는다
      if (handle == kMid) await _snapEdges({0});
      if (handle == kPts + kMid) await _snapEdges({2});
    }
  }

  /// 변 번호(0=위 1=오른쪽 2=아래 3=왼쪽)들을 가까운 실제 종이 경계에 붙인다. 확실하지 않으면 그대로 둔다.
  Future<void> _snapEdges(Set<int> edges) async {
    if (!_magnetOn) return;
    final seq = ++_snapSeq;
    final quad = [_shape.top.first, _shape.top.last, _shape.bottom.last, _shape.bottom.first];
    // 변 위의 점들: 위·아래는 조절점(모서리·제본선 제외), 좌우는 곡선 위 세 지점
    List<Offset> pointsOf(int e) {
      switch (e) {
        case 0:
          return [for (var k = 1; k < kPts - 1; k++) if (!(_shape.spread && k == kMid)) _shape.top[k]];
        case 2:
          return [for (var k = 1; k < kPts - 1; k++) if (!(_shape.spread && k == kMid)) _shape.bottom[k]];
        default:
          final side = _shape.sideCurve(left: e == 3, n: 4);
          return [side[1], side[2], side[3]];
      }
    }

    final results = await Future.wait([
      for (final e in edges) compute(snapEdgePoints, (_jpg, quad, e, pointsOf(e))),
    ]);
    if (!mounted || seq != _snapSeq || _dragging != null) return;
    setState(() {
      var i = 0;
      for (final e in edges) {
        final r = results[i++];
        switch (e) {
          case 0:
            var j = 0;
            for (var k = 1; k < kPts - 1; k++) {
              if (_shape.spread && k == kMid) continue;
              _shape.top[k] = r[j++];
            }
          case 2:
            var j = 0;
            for (var k = 1; k < kPts - 1; k++) {
              if (_shape.spread && k == kMid) continue;
              _shape.bottom[k] = r[j++];
            }
          default:
            // 붙은 세 점으로 휨(가운데가 곧은 선에서 벗어난 정도)을 다시 구한다
            final left = e == 3;
            final a = left ? _shape.top.first : _shape.top.last, b = left ? _shape.bottom.first : _shape.bottom.last;
            var sum = Offset.zero;
            for (var k = 0; k < 3; k++) {
              final v = (k + 1) / 4;
              sum += (r[k] - Offset.lerp(a, b, v)!) / (4 * v * (1 - v));
            }
            final bow = sum / 3;
            _shape = PageShape(_shape.top, _shape.bottom, _shape.spread,
                leftBow: left ? bow : _shape.leftBow, rightBow: left ? _shape.rightBow : bow);
        }
      }
    });
  }

  /// 네 모서리를 한꺼번에 종이 모서리에 붙인다 (자동 인식 버튼)
  Future<void> _snapAll() async {
    final seq = ++_snapSeq;
    final quad = [_shape.top.first, _shape.top.last, _shape.bottom.last, _shape.bottom.first];
    final res = await compute(snapCorners, (_jpg, quad, [0, 1, 2, 3]));
    if (!mounted || seq != _snapSeq || _dragging != null || res.isEmpty) return;
    HapticFeedback.selectionClick();
    const handleOf = {0: 0, 1: kPts - 1, 2: 2 * kPts - 1, 3: kPts};
    setState(() {
      for (final e in res.entries) {
        _setPoint(handleOf[e.key]!, e.value);
      }
    });
    await _snapEdges({0, 1, 2, 3});
  }

  /// 점 하나를 옮기면 그 변 전체를 자연스럽게 다시 그린다.
  /// - 모서리·제본선: 변의 굴곡 모양은 유지한 채 따라 움직임
  /// - 가운데 점(한 장): 변 전체가 부드러운 곡선(포물선)으로 휨
  void _setPoint(int i, Offset p) {
    if (i == _leftMid || i == _rightMid) {
      // 변 가운데를 끌면 그 변이 포물선으로 휜다
      final left = i == _leftMid;
      final straight = Offset.lerp(
          left ? _shape.top.first : _shape.top.last, left ? _shape.bottom.first : _shape.bottom.last, 0.5)!;
      _shape = PageShape(_shape.top, _shape.bottom, _shape.spread,
          leftBow: left ? p - straight : _shape.leftBow, rightBow: left ? _shape.rightBow : p - straight);
      return;
    }
    final edge = i < kPts ? _shape.top : _shape.bottom;
    final k = i < kPts ? i : i - kPts;
    if (k == kMid && !_shape.spread) {
      final a = edge.first, b = edge.last;
      final c = p * 2 - (a + b) / 2; // 가운데를 지나는 2차 곡선의 조절점
      for (var j = 1; j < kPts - 1; j++) {
        final t = j / (kPts - 1);
        edge[j] = a * ((1 - t) * (1 - t)) + c * (2 * t * (1 - t)) + b * (t * t);
      }
      return;
    }
    // 이 점이 끝인 구간들만 모양을 유지한 채 다시 맞춘다
    final anchors = _shape.spread ? [0, kMid, kPts - 1] : [0, kPts - 1];
    for (var s = 0; s < anchors.length - 1; s++) {
      final i0 = anchors[s], i1 = anchors[s + 1];
      if (k != i0 && k != i1) continue;
      _reanchor(edge, i0, i1, k == i0 ? p : edge[i0], k == i1 ? p : edge[i1]);
    }
    edge[k] = p;
  }

  /// edge[i0..i1] 사이 점들을, 양 끝이 newA·newB로 옮겨질 때 같은 굴곡 모양으로 따라오게 한다.
  static void _reanchor(List<Offset> edge, int i0, int i1, Offset newA, Offset newB) {
    final oa = edge[i0], ob = edge[i1];
    final od = ob - oa, nd = newB - newA;
    final ol = od.distance, nl = nd.distance;
    if (ol < 1e-6 || nl < 1e-6) return;
    final oDir = od / ol, oNrm = Offset(-oDir.dy, oDir.dx);
    final nDir = nd / nl, nNrm = Offset(-nDir.dy, nDir.dx);
    final sc = nl / ol;
    for (var j = i0 + 1; j < i1; j++) {
      final t = (j - i0) / (i1 - i0);
      final rel = edge[j] - Offset.lerp(oa, ob, t)!;
      final along = rel.dx * oDir.dx + rel.dy * oDir.dy;
      final across = rel.dx * oNrm.dx + rel.dy * oNrm.dy;
      edge[j] = Offset.lerp(newA, newB, t)! + nDir * (along * sc) + nNrm * (across * sc);
    }
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
        backgroundColor: Colors.black,
        actions: [
          // 자석 켜기/끄기
          TextButton.icon(
            onPressed: () => setState(() => _magnetOn = !_magnetOn),
            icon: Icon(Icons.attractions_rounded,
                color: _magnetOn ? const Color(0xFF4FE3C1) : Colors.white38),
            label: Text(_magnetOn ? '자석 켬' : '자석 끔',
                style: TextStyle(color: _magnetOn ? const Color(0xFF4FE3C1) : Colors.white54)),
          ),
        ],
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('윤곽 수정'),
          Text('파랑 점=모서리(종이 끝에 붙어요) · 분홍 점=변 가운데(굴곡)',
              style: TextStyle(fontSize: 12, color: Colors.white60)),
        ]),
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
                // 변 휨은 방향·크기 벡터라서 배율만 곱한다
                final screenShape = PageShape(top, bottom, _shape.spread,
                    leftBow: _shape.leftBow * s, rightBow: _shape.rightBow * s);
                final handles = [...top, ...bottom, toScreen(_sideMid(true)), toScreen(_sideMid(false))];

                return GestureDetector(
                  onPanStart: (e) {
                    _snapSeq++;
                    _dragFrom = null;
                    // 손가락에서 가장 가까운 조절점을 잡는다
                    int? best;
                    for (final i in _visible) {
                      if (best == null ||
                          (handles[i] - e.localPosition).distance < (handles[best] - e.localPosition).distance) {
                        best = i;
                      }
                    }
                    if (best != null && (handles[best] - e.localPosition).distance < 56) {
                      _dragging = best;
                      _dragFrom = _point(best);
                    }
                  },
                  onPanUpdate: (e) {
                    final i = _dragging;
                    if (i == null) return;
                    setState(() => _setPoint(i, toImage(e.localPosition)));
                  },
                  onPanEnd: (_) {
                    final i = _dragging;
                    setState(() => _dragging = null);
                    if (i != null) _afterDrop(i);
                  },
                  child: Stack(children: [
                    Positioned(
                      left: ox,
                      top: oy,
                      width: d.width * s,
                      height: d.height * s,
                      child: Image.memory(_jpg, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                          painter: _ShapePainter(screenShape, handles, _dragging, _snapped)),
                    ),
                    if (_dragging != null)
                      _Magnifier(
                          image: _jpg, d: d, at: _point(_dragging!), screen: handles[_dragging!], box: box),
                  ]),
                );
              }),
            ),
          ),
          // 빠른 도구: 이름이 붙은 버튼으로
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              _QuickTool(
                icon: Icons.auto_fix_high_rounded,
                label: '자동 인식',
                onTap: () {
                  setState(() => _shape = d.shape.copy());
                  _snapAll();
                },
              ),
              _QuickTool(
                icon: Icons.fullscreen_rounded,
                label: '사진 전체',
                onTap: () => setState(() => _shape = PageShape.quad([
                      Offset.zero,
                      Offset(d.width.toDouble(), 0),
                      Offset(d.width.toDouble(), d.height.toDouble()),
                      Offset(0, d.height.toDouble()),
                    ], false)),
              ),
              _QuickTool(icon: Icons.straighten_rounded, label: '굴곡 없이', onTap: _straighten),
              _QuickTool(
                icon: _shape.spread ? Icons.menu_book_rounded : Icons.description_outlined,
                label: _shape.spread ? '양면 → 2장' : '한 장',
                active: _shape.spread,
                onTap: () => setState(() => _shape = _shape.copy(spread: !_shape.spread)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _shape),
                icon: const Icon(Icons.check_rounded),
                label: Text(_shape.spread ? '이대로 펴기 (2장)' : '이대로 펴기'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.shape, this.pts, this.active, this.snapped);

  /// 화면 좌표로 바꾼 윤곽
  final PageShape shape;

  /// 손잡이 위치 (위 점들, 아래 점들, 왼쪽 변 가운데, 오른쪽 변 가운데)
  final List<Offset> pts;

  /// 방금 종이 모서리에 붙은 점 (빛나는 고리)
  final int? snapped;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final top = shape.top, bottom = shape.bottom, spread = shape.spread;
    final t = sampleCurve(top), b = sampleCurve(bottom);
    final path = Path()..addPolygon(shape.outline(), true);
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
    // 펴질 모양을 짐작할 수 있게 가로 안내선 (좌우 변이 휘면 같이 휜다)
    final guide = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var v = 0.25; v < 1; v += 0.25) {
      canvas.drawPoints(
          PointMode.polygon,
          [
            for (var i = 0; i < t.length; i++)
              Offset.lerp(t[i], b[i], v)! +
                  (shape.leftBow * (1 - i / (t.length - 1)) + shape.rightBow * (i / (t.length - 1))) *
                      (4 * v * (1 - v)),
          ],
          guide);
    }
    if (spread) {
      canvas.drawLine(top[kMid], bottom[kMid], line..color = Colors.orangeAccent);
    }
    for (var i = 0; i < pts.length; i++) {
      // 잡을 수 있는 점만 그린다 (모서리 4개 + 변 가운데 4개)
      if (!_CropScreenState._visible.contains(i)) continue;
      final corner = i == 0 || i == kPts - 1 || i == kPts || i == 2 * kPts - 1;
      final spine = spread && (i == kMid || i == kPts + kMid);
      final r = i == active ? 17.0 : (corner ? 13.0 : 11.0);
      if (i == snapped) {
        canvas.drawCircle(pts[i], r + 9,
            Paint()
              ..color = const Color(0xFF4FE3C1)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
      }
      canvas.drawCircle(pts[i], r, Paint()..color = Colors.white);
      canvas.drawCircle(
          pts[i],
          r - 3,
          Paint()
            ..color = spine
                ? Colors.orangeAccent
                : corner
                    ? Colors.lightBlueAccent // 모서리: 파랑
                    : Colors.pinkAccent); // 변 가운데: 분홍 (모서리와 한눈에 구분)
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

class _QuickTool extends StatelessWidget {
  const _QuickTool({required this.icon, required this.label, required this.onTap, this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF4FE3C1) : Colors.white;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
