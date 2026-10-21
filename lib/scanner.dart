import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 페이지 윤곽. 위·아래 가장자리를 각각 조절점 5개(왼쪽 끝 → 오른쪽 끝)로 표현한다.
/// 양면(spread) 모드에서는 가운데 점(인덱스 2)이 책 가운데 접히는 선(제본선)이다.
class PageShape {
  PageShape(this.top, this.bottom, this.spread);

  final List<Offset> top;
  final List<Offset> bottom;
  final bool spread;

  PageShape copy({bool? spread}) => PageShape([...top], [...bottom], spread ?? this.spread);

  /// 네 모서리만으로 만든 곧은 사각형
  factory PageShape.quad(List<Offset> c, bool spread) => PageShape(
        [for (var i = 0; i <= 4; i++) Offset.lerp(c[0], c[1], i / 4)!],
        [for (var i = 0; i <= 4; i++) Offset.lerp(c[3], c[2], i / 4)!],
        spread,
      );
}

/// 촬영 사진을 읽고 페이지 윤곽을 찾은 결과.
class Detection {
  Detection(this.jpg, this.width, this.height, this.shape, this.found);

  /// EXIF 회전이 적용된 원본 (화면 표시와 보정에 공통 사용)
  final Uint8List jpg;
  final int width;
  final int height;
  final PageShape shape;

  /// 실제로 페이지 윤곽을 찾았는지 (못 찾으면 기본 사각형)
  final bool found;
}

/// 보정 후 색 처리 방식.
enum ScanMode { original, enhanced, gray, bw }

const scanModeLabels = {
  ScanMode.original: '원본',
  ScanMode.enhanced: '선명하게',
  ScanMode.gray: '흑백',
  ScanMode.bw: '스캔(B/W)',
};

// ───────────────────────── 검출 ─────────────────────────

/// isolate에서 실행된다: 사진 경로 → 페이지 윤곽(모서리 + 굴곡) 검출.
Future<Detection> detectPage(String path) async {
  final img = cv.imread(path, flags: cv.IMREAD_COLOR);
  final w = img.cols, h = img.rows;
  final (_, jpg) = cv.imencode('.jpg', img, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));

  // 작게 줄여서 윤곽 찾기 (속도와 잡음 감소)
  final scale = 800 / math.max(w, h);
  final small = cv.resize(img, ((w * scale).round(), (h * scale).round()));
  final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
  final quad = _findQuad(gray);

  if (quad == null) {
    final c = [
      Offset(w * .05, h * .05),
      Offset(w * .95, h * .05),
      Offset(w * .95, h * .95),
      Offset(w * .05, h * .95),
    ];
    return Detection(jpg, w, h, PageShape.quad(c, w > h * 1.15), false);
  }

  final img2 = _Gray(gray);
  final widthPx = ((quad[1] - quad[0]).distance + (quad[2] - quad[3]).distance) / 2;
  final heightPx = ((quad[3] - quad[0]).distance + (quad[2] - quad[1]).distance) / 2;
  final spread = widthPx > heightPx * 1.15; // 가로로 넓으면 펼친 양면으로 본다

  // 제본선 위치 (양면일 때만): 가운데 부근에서 가장 어두운 세로줄
  var spineS = 0.5;
  if (spread) spineS = _findSpine(img2, quad);

  final ss = spread ? [0.0, spineS / 2, spineS, (1 + spineS) / 2, 1.0] : [0.0, .25, .5, .75, 1.0];
  final center = quad.reduce((a, b) => a + b) / 4;
  final top = [for (final s in ss) _snapEdge(img2, quad[0], quad[1], s, center, heightPx)];
  final bottom = [for (final s in ss) _snapEdge(img2, quad[3], quad[2], s, center, heightPx)];
  Offset up(Offset p) => p / scale;
  return Detection(jpg, w, h, PageShape(top.map(up).toList(), bottom.map(up).toList(), spread), true);
}

/// 가장 큰 사각형 윤곽(작은 이미지 좌표, 좌상·우상·우하·좌하 순).
List<Offset>? _findQuad(cv.Mat gray) {
  final blur = cv.gaussianBlur(gray, (5, 5), 0);
  final edges = cv.canny(blur, 50, 150);
  final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
  final closed = cv.dilate(edges, kernel, iterations: 2);
  final (contours, _) = cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  final minArea = gray.cols * gray.rows * 0.15;
  List<Offset>? best;
  double bestArea = 0;
  for (final c in contours) {
    final area = cv.contourArea(c);
    if (area < minArea || area <= bestArea) continue;
    // 책은 가장자리가 휘어 있어 꼭짓점이 많다 → 볼록 껍질을 크게 근사해서 4점을 찾는다
    final hull = cv.VecPoint.fromMat(cv.convexHull(c));
    final peri = cv.arcLength(hull, true);
    for (final k in [0.02, 0.03, 0.05, 0.07, 0.1]) {
      final approx = cv.approxPolyDP(hull, k * peri, true);
      if (approx.length == 4) {
        best = [for (final p in approx) Offset(p.x.toDouble(), p.y.toDouble())];
        bestArea = area;
        break;
      }
    }
  }
  return best == null ? null : orderCorners(best);
}

/// 네 점을 좌상, 우상, 우하, 좌하 순으로 정렬.
List<Offset> orderCorners(List<Offset> pts) {
  final c = pts.reduce((a, b) => a + b) / 4;
  final sorted = [...pts]
    ..sort((a, b) => math.atan2(a.dy - c.dy, a.dx - c.dx)
        .compareTo(math.atan2(b.dy - c.dy, b.dx - c.dx)));
  var start = 0;
  for (var i = 1; i < 4; i++) {
    if (sorted[i].dx + sorted[i].dy < sorted[start].dx + sorted[start].dy) start = i;
  }
  return [for (var i = 0; i < 4; i++) sorted[(start + i) % 4]];
}

/// 픽셀 값을 빠르게 읽기 위한 회색 이미지 래퍼.
class _Gray {
  _Gray(cv.Mat m)
      : w = m.cols,
        h = m.rows,
        data = Uint8List.fromList(m.data);

  final int w, h;
  final Uint8List data;

  double at(Offset p) {
    final x = p.dx.round().clamp(0, w - 1), y = p.dy.round().clamp(0, h - 1);
    return data[y * w + x].toDouble();
  }
}

/// 직선 a→b 위 s 지점에서, 수직 방향으로 실제 종이 가장자리(어두움→밝음 경계)를 찾는다.
/// 책 가장자리의 휘어짐은 이렇게 여러 지점을 끌어당겨 따라간다.
Offset _snapEdge(_Gray g, Offset a, Offset b, double s, Offset center, double pageH) {
  final base = Offset.lerp(a, b, s)!;
  if (s == 0 || s == 1) return base; // 모서리는 사각형 검출 결과를 그대로 쓴다
  final d = b - a;
  var n = Offset(-d.dy, d.dx) / d.distance;
  if ((center - base).dx * n.dx + (center - base).dy * n.dy < 0) n = -n; // 페이지 안쪽 방향

  final band = pageH * 0.12;
  final offsets = <double>[];
  for (var j = -2; j <= 2; j++) {
    final p0 = Offset.lerp(a, b, (s + j * 0.008).clamp(0.0, 1.0))!;
    double bestT = 0, bestG = 18; // 이보다 약한 경계는 무시
    for (var t = -band; t <= band; t += 1) {
      final grad = g.at(p0 + n * (t + 3)) - g.at(p0 + n * (t - 3));
      if (grad > bestG) {
        bestG = grad;
        bestT = t;
      }
    }
    offsets.add(bestT);
  }
  offsets.sort();
  return base + n * offsets[2]; // 중앙값
}

/// 양면 사진에서 제본선(가운데 그림자)의 위치를 0~1 비율로 찾는다.
double _findSpine(_Gray g, List<Offset> q) {
  var bestS = 0.5, bestV = double.infinity;
  for (var s = 0.35; s <= 0.65; s += 0.005) {
    final t = Offset.lerp(q[0], q[1], s)!, b = Offset.lerp(q[3], q[2], s)!;
    var sum = 0.0;
    for (var k = 1; k < 30; k++) {
      sum += g.at(Offset.lerp(t, b, k / 30)!);
    }
    // 가운데에 가까울수록 약간 우대 (그림 때문에 엉뚱한 곳이 잡히는 것 방지)
    final v = sum / 29 + (s - 0.5).abs() * 40;
    if (v < bestV) {
      bestV = v;
      bestS = s;
    }
  }
  return bestS;
}

// ───────────────────────── 펴기 ─────────────────────────

const _segSamples = 40; // 조절점 사이 곡선 샘플 수

/// 조절점을 지나는 부드러운 곡선(Catmull-Rom)을 촘촘한 점들로 만든다.
/// 조절점 k는 결과의 k * _segSamples 번째 점이다.
List<Offset> sampleCurve(List<Offset> c) {
  final out = <Offset>[];
  for (var i = 0; i < c.length - 1; i++) {
    final p0 = c[math.max(i - 1, 0)], p1 = c[i], p2 = c[i + 1], p3 = c[math.min(i + 2, c.length - 1)];
    for (var k = 0; k < _segSamples; k++) {
      final t = k / _segSamples, t2 = t * t, t3 = t2 * t;
      out.add((p1 * 2 +
              (p2 - p0) * t +
              (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 +
              (p1 * 3 - p0 - p2 * 3 + p3) * t3) *
          0.5);
    }
  }
  out.add(c.last);
  return out;
}

/// 곡선 위에서 길이 비율 u(0~1) 지점의 좌표.
Offset _atLength(List<Offset> pts, List<double> cum, double u) {
  final target = u * cum.last;
  var i = 1;
  while (i < cum.length - 1 && cum[i] < target) {
    i++;
  }
  final seg = cum[i] - cum[i - 1];
  final t = seg == 0 ? 0.0 : (target - cum[i - 1]) / seg;
  return Offset.lerp(pts[i - 1], pts[i], t)!;
}

List<double> _cumLength(List<Offset> pts) {
  final cum = [0.0];
  for (var i = 1; i < pts.length; i++) {
    cum.add(cum.last + (pts[i] - pts[i - 1]).distance);
  }
  return cum;
}

/// 휘어진 위·아래 가장자리 사이를 격자로 나눠 평평한 직사각형으로 편다.
cv.Mat _dewarp(cv.Mat img, List<Offset> top, List<Offset> bottom) {
  final cumT = _cumLength(top), cumB = _cumLength(bottom);
  final outW = ((cumT.last + cumB.last) / 2).round();
  final outH = (((bottom.first - top.first).distance +
              (bottom.last - top.last).distance +
              (bottom[bottom.length ~/ 2] - top[top.length ~/ 2]).distance) /
          3)
      .round();

  // 8px 간격의 성긴 격자에서 계산하고 확대 (선형 보간이므로 결과는 같다)
  const step = 8;
  final gw = outW ~/ step + 2, gh = outH ~/ step + 2;
  final mx = Float32List(gw * gh), my = Float32List(gw * gh);
  for (var gx = 0; gx < gw; gx++) {
    final u = math.min(gx * step / (outW - 1), 1.0);
    final t = _atLength(top, cumT, u), b = _atLength(bottom, cumB, u);
    for (var gy = 0; gy < gh; gy++) {
      final v = math.min(gy * step / (outH - 1), 1.0);
      final p = Offset.lerp(t, b, v)!;
      mx[gy * gw + gx] = p.dx;
      my[gy * gw + gx] = p.dy;
    }
  }
  final sw = (gw - 1) * step + 1, sh = (gh - 1) * step + 1;
  final mapX = cv.resize(cv.Mat.fromList(gh, gw, cv.MatType.CV_32FC1, mx), (sw, sh));
  final mapY = cv.resize(cv.Mat.fromList(gh, gw, cv.MatType.CV_32FC1, my), (sw, sh));
  final full = cv.remap(img, mapX, mapY, cv.INTER_CUBIC, borderMode: cv.BORDER_REPLICATE);
  return full.region(cv.Rect(0, 0, outW, outH)).clone();
}

/// 색 처리.
cv.Mat _applyMode(cv.Mat out, ScanMode mode) {
  if (mode == ScanMode.original) return out;
  // 배경(종이) 밝기를 추정해서 나누면 그림자와 조명 얼룩이 사라진다
  final gray = cv.cvtColor(out, cv.COLOR_BGR2GRAY);
  final k = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
  final bg = cv.medianBlur(cv.dilate(gray, k), 21);
  return switch (mode) {
    ScanMode.enhanced => cv.divide(out, cv.cvtColor(bg, cv.COLOR_GRAY2BGR), scale: 255),
    ScanMode.gray => cv.divide(gray, bg, scale: 255),
    ScanMode.bw => cv.adaptiveThreshold(cv.divide(gray, bg, scale: 255), 255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 31, 10),
    ScanMode.original => out,
  };
}

/// isolate에서 실행된다: 윤곽대로 펴고 색 처리 → JPG 목록 (양면이면 왼쪽, 오른쪽 2장).
Future<List<Uint8List>> warpPage((Uint8List, PageShape, ScanMode) args) async {
  final (jpg, shape, mode) = args;
  final img = cv.imdecode(jpg, cv.IMREAD_COLOR);
  final top = sampleCurve(shape.top), bottom = sampleCurve(shape.bottom);

  final parts = shape.spread
      ? [
          (top.sublist(0, 2 * _segSamples + 1), bottom.sublist(0, 2 * _segSamples + 1)),
          (top.sublist(2 * _segSamples), bottom.sublist(2 * _segSamples)),
        ]
      : [(top, bottom)];

  return [
    for (final (t, b) in parts)
      cv.imencode('.jpg', _applyMode(_dewarp(img, t, b), mode),
          params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 92])).$2,
  ];
}
