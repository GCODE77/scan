import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 페이지 윤곽. 위·아래 가장자리를 각각 조절점 5개(왼쪽 끝 → 오른쪽 끝)로 표현한다.
/// 양면(spread) 모드에서는 가운데 점(인덱스 [kMid])이 책 가운데 접히는 선(제본선)이다.
/// 가장자리 하나의 조절점 수 (양 끝 모서리 포함)
const kPts = 7;
const kMid = kPts ~/ 2;

class PageShape {
  PageShape(this.top, this.bottom, this.spread);

  final List<Offset> top;
  final List<Offset> bottom;
  final bool spread;

  PageShape copy({bool? spread}) => PageShape([...top], [...bottom], spread ?? this.spread);

  /// 네 모서리만으로 만든 곧은 사각형
  factory PageShape.quad(List<Offset> c, bool spread) => PageShape(
        [for (var i = 0; i < kPts; i++) Offset.lerp(c[0], c[1], i / (kPts - 1))!],
        [for (var i = 0; i < kPts; i++) Offset.lerp(c[3], c[2], i / (kPts - 1))!],
        spread,
      );
}

/// 촬영 사진을 읽고 페이지 윤곽을 찾은 결과.
class Detection {
  Detection(Uint8List jpg, this.width, this.height, this.shape, this.found) : _mem = jpg;

  /// 보관함에서 불러온 것: 원본 사진은 필요할 때만 파일에서 읽는다 (메모리 절약)
  Detection.stored(String this.path, this.width, this.height, this.shape) : found = true;

  Uint8List? _mem;

  /// 보관함에 저장된 원본 사진 경로 (저장 전이면 null)
  String? path;

  /// EXIF 회전이 적용된 원본 (화면 표시와 보정에 공통 사용)
  Uint8List get jpg => _mem ?? File(path!).readAsBytesSync();

  /// 파일로 저장한 뒤에는 메모리에서 내린다
  void storedAt(String p) {
    path = p;
    _mem = null;
  }

  final int width;
  final int height;
  final PageShape shape;

  /// 실제로 페이지 윤곽을 찾았는지 (못 찾으면 기본 사각형)
  final bool found;
}

/// 필터 (색 처리 방식). 기본은 원본.
enum ScanMode { original, bright, magic, gray, bw }

const scanModeLabels = {
  ScanMode.original: '원본',
  ScanMode.bright: '밝게하기',
  ScanMode.magic: '매직 컬러',
  ScanMode.gray: '흑백',
  ScanMode.bw: '스캔 B/W',
};

// ───────────────────────── 검출 ─────────────────────────

/// isolate에서 실행된다: 사진 경로 → 페이지 윤곽(모서리 + 굴곡) 검출.
Future<Detection> detectPage(String path) async {
  final img = cv.imread(path, flags: cv.IMREAD_COLOR);
  final w = img.cols, h = img.rows;
  final (_, jpg) = cv.imencode('.jpg', img, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));

  // 작게 줄여서 분석 (속도와 잡음 감소)
  final scale = 800 / math.max(w, h);
  final small = cv.resize(img, ((w * scale).round(), (h * scale).round()), interpolation: cv.INTER_AREA);
  final blur = cv.gaussianBlur(cv.cvtColor(small, cv.COLOR_BGR2GRAY), (7, 7), 0);
  final paper = _paperMask(blur);

  Detection fallback() {
    // 못 찾으면 사진 전체를 페이지로 (사용자가 원하면 나중에 자르기로 조정)
    final c = [Offset.zero, Offset(w - 1.0, 0), Offset(w - 1.0, h - 1.0), Offset(0, h - 1.0)];
    return Detection(jpg, w, h, PageShape.quad(c, false), false);
  }

  if (paper == null) return fallback();
  final (blob, quad0) = paper;
  final g = _Gray(blur), m = _Gray(blob);
  var [tl, tr, br, bl] = quad0;

  // 제본선 (펼친 책의 가운데 골짜기)
  final spine = _findSpine(g, tl, tr, br, bl);
  var spread = false;
  if (spine != null) {
    final (st, sb) = spine;
    final wl = ((st - tl).distance + (sb - bl).distance) / 2;
    final wr = ((tr - st).distance + (br - sb).distance) / 2;
    if (wl < wr * 0.6) {
      // 왼쪽은 사진 밖으로 잘린 조각 → 오른쪽 페이지만
      tl = st;
      bl = sb;
    } else if (wr < wl * 0.6) {
      tr = st;
      br = sb;
    } else {
      spread = true;
    }
  }

  // 위·아래 가장자리를 따라갈 기준점 (양면이면 가운데 점이 제본선 위에 오도록)
  List<Offset> bases(Offset a, Offset mid, Offset b) => spread
      ? [
          for (var i = 0; i <= kMid; i++) Offset.lerp(a, mid, i / kMid)!,
          for (var i = 1; i <= kMid; i++) Offset.lerp(mid, b, i / kMid)!,
        ]
      : [for (var i = 0; i < kPts; i++) Offset.lerp(a, b, i / (kPts - 1))!];

  final center = (tl + tr + br + bl) / 4;
  final pageH = ((bl - tl).distance + (br - tr).distance) / 2;
  final top = _traceEdge(m, bases(tl, spine?.$1 ?? tl, tr), center, pageH);
  final bottom = _traceEdge(m, bases(bl, spine?.$2 ?? bl, br), center, pageH);
  Offset up(Offset p) => Offset((p.dx / scale).clamp(0, w - 1.0), (p.dy / scale).clamp(0, h - 1.0));
  return Detection(jpg, w, h, PageShape(top.map(up).toList(), bottom.map(up).toList(), spread), true);
}

/// 종이 영역: 종이는 배경보다 밝다 (자동 문턱값). 가장 큰 덩어리와 그 사각형.
(cv.Mat, List<Offset>)? _paperMask(cv.Mat blur) {
  final (_, bin) = cv.threshold(blur, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
  // 글자·그림 구멍을 메우고 잔티를 지운다
  var mask = cv.morphologyEx(bin, cv.MORPH_CLOSE, cv.getStructuringElement(cv.MORPH_RECT, (15, 15)),
      iterations: 2);
  mask = cv.morphologyEx(mask, cv.MORPH_OPEN, cv.getStructuringElement(cv.MORPH_RECT, (9, 9)));
  final (contours, _) = cv.findContours(mask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  var bestIdx = -1;
  var bestArea = blur.cols * blur.rows * 0.12; // 너무 작으면 종이가 아니다
  for (var i = 0; i < contours.length; i++) {
    final a = cv.contourArea(contours[i]);
    if (a > bestArea) {
      bestArea = a;
      bestIdx = i;
    }
  }
  if (bestIdx < 0) return null;

  final blob = cv.Mat.zeros(blur.rows, blur.cols, cv.MatType.CV_8UC1);
  cv.drawContours(blob, contours, bestIdx, cv.Scalar.all(255), thickness: -1);

  // 볼록 껍질을 사각형으로 근사, 안 되면 극점 4개
  final hull = cv.VecPoint.fromMat(cv.convexHull(contours[bestIdx]));
  final peri = cv.arcLength(hull, true);
  List<Offset>? quad;
  for (final k in [0.02, 0.03, 0.05, 0.07, 0.1]) {
    final approx = cv.approxPolyDP(hull, k * peri, true);
    if (approx.length == 4) {
      quad = [for (final p in approx) Offset(p.x.toDouble(), p.y.toDouble())];
      break;
    }
  }
  if (quad == null) {
    final pts = [for (final p in hull) Offset(p.x.toDouble(), p.y.toDouble())];
    Offset by(double Function(Offset) f, bool max) =>
        pts.reduce((a, b) => (f(a) > f(b)) == max ? a : b);
    quad = [
      by((p) => p.dx + p.dy, false),
      by((p) => p.dx - p.dy, true),
      by((p) => p.dx + p.dy, true),
      by((p) => p.dx - p.dy, false),
    ];
  }
  return (blob, orderCorners(quad));
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

  double at(double x, double y) {
    final xi = x.round().clamp(0, w - 1), yi = y.round().clamp(0, h - 1);
    return data[yi * w + xi].toDouble();
  }

  /// 마스크용: 사진 밖은 종이가 아니다
  bool on(Offset p) {
    final x = p.dx.round(), y = p.dy.round();
    return x >= 0 && y >= 0 && x < w && y < h && data[y * w + x] > 0;
  }
}

/// 가장자리 곡선 추적: 기준점마다 바깥에서 안쪽으로 걸어가며 처음 종이를 만나는 곳.
/// 이웃과 동떨어진 값(잡음)은 이웃 평균으로 바로잡는다.
List<Offset> _traceEdge(_Gray mask, List<Offset> bases, Offset center, double pageH) {
  final n = bases.length;
  final normals = <Offset>[];
  for (var i = 0; i < n; i++) {
    final d = bases[math.min(i + 1, n - 1)] - bases[math.max(i - 1, 0)];
    var nv = Offset(-d.dy, d.dx) / d.distance;
    final toC = center - bases[i];
    if (toC.dx * nv.dx + toC.dy * nv.dy < 0) nv = -nv; // 페이지 안쪽 방향
    normals.add(nv);
  }

  final from = -(pageH * 0.1).round(), to = (pageH * 0.18).round();
  final off = <double>[];
  for (var i = 0; i < n; i++) {
    double? found;
    for (var t = from; t <= to && found == null; t++) {
      final q = bases[i] + normals[i] * t.toDouble();
      // 5픽셀 연속 종이여야 진짜 가장자리 (잡음 제외)
      if (mask.on(q) && [for (var k = 1; k <= 5; k++) mask.on(q + normals[i] * k.toDouble())].every((v) => v)) {
        found = t.toDouble();
      }
    }
    off.add(found ?? 0);
  }

  final limit = pageH * 0.04;
  for (var i = 1; i < n - 1; i++) {
    final expect = (off[i - 1] + off[i + 1]) / 2;
    if ((off[i] - expect).abs() > limit) off[i] = expect;
  }
  return [for (var i = 0; i < n; i++) bases[i] + normals[i] * off[i]];
}

/// 제본선(펼친 책 가운데 골짜기)을 찾는다. 기울어진 직선(위 점, 아래 점)으로.
/// 선 위 점이 양옆보다 어두운 정도의 '중앙값'을 본다 → 끊김 없이 이어진 골짜기만 높게 나오고
/// 띄엄띄엄 있는 글자·음표는 걸러진다. 없으면 null.
(Offset, Offset)? _findSpine(_Gray g, Offset tl, Offset tr, Offset br, Offset bl) {
  double valley(Offset a, Offset b) {
    var best = 0.0;
    for (final d in const [5, 12]) {
      final v = <double>[];
      for (var k = 0; k < 40; k++) {
        final p = Offset.lerp(a, b, 0.1 + 0.8 * k / 39)!;
        if (p.dx < d || p.dx >= g.w - d || p.dy < 0 || p.dy >= g.h) continue;
        v.add(math.min(g.at(p.dx - d, p.dy), g.at(p.dx + d, p.dy)) - g.at(p.dx, p.dy));
      }
      if (v.length > 20) {
        v.sort();
        best = math.max(best, v[v.length ~/ 2]);
      }
    }
    return best;
  }

  (Offset, Offset)? best;
  var bestScore = 6.0; // 이보다 약하면 제본선 없음 (한 쪽 페이지)
  for (var i = 0; i <= 120; i++) {
    final s = 0.08 + 0.84 * i / 120;
    final a = Offset.lerp(tl, tr, s)!;
    final b0 = Offset.lerp(bl, br, s)!;
    for (var db = -60; db <= 60; db += 4) {
      final b = b0 + Offset(db.toDouble(), 0);
      final v = valley(a, b);
      if (v > bestScore) {
        bestScore = v;
        best = (a, b);
      }
    }
  }
  return best;
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
  if (mode == ScanMode.bright) return out.convertTo(cv.MatType.CV_8UC3, alpha: 1.15, beta: 25);
  // 배경(종이) 밝기를 추정해서 나누면 그림자와 조명 얼룩이 사라진다
  final gray = cv.cvtColor(out, cv.COLOR_BGR2GRAY);
  final k = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
  final bg = cv.medianBlur(cv.dilate(gray, k), 21);
  return switch (mode) {
    ScanMode.magic => cv.divide(out, cv.cvtColor(bg, cv.COLOR_GRAY2BGR), scale: 255),
    ScanMode.gray => cv.divide(gray, bg, scale: 255),
    ScanMode.bw => cv.adaptiveThreshold(cv.divide(gray, bg, scale: 255), 255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 31, 10),
    ScanMode.original || ScanMode.bright => out,
  };
}

/// isolate에서 실행된다: 윤곽대로 편 원본 색 JPG 목록 (양면이면 왼쪽, 오른쪽 2장).
/// 필터와 회전은 이 결과 위에 [renderPage]로 따로 입힌다.
Future<List<Uint8List>> warpFlat((Uint8List, PageShape) args) async {
  final (jpg, shape) = args;
  final img = cv.imdecode(jpg, cv.IMREAD_COLOR);
  final top = sampleCurve(shape.top), bottom = sampleCurve(shape.bottom);

  final parts = shape.spread
      ? [
          (top.sublist(0, kMid * _segSamples + 1), bottom.sublist(0, kMid * _segSamples + 1)),
          (top.sublist(kMid * _segSamples), bottom.sublist(kMid * _segSamples)),
        ]
      : [(top, bottom)];

  return [for (final (t, b) in parts) _encode(_dewarp(img, t, b))];
}

/// isolate에서 실행된다: 편 이미지에 필터·회전 적용. maxSide를 주면 미리보기용으로 작게.
Future<Uint8List> renderPage((Uint8List, ScanMode, int, int?) args) async {
  final (flat, mode, quarterTurns, maxSide) = args;
  var img = cv.imdecode(flat, cv.IMREAD_COLOR);
  if (maxSide != null) {
    final s = maxSide / math.max(img.cols, img.rows);
    if (s < 1) img = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
  }
  img = _applyMode(img, mode);
  final r = quarterTurns % 4;
  if (r != 0) {
    img = cv.rotate(img, const [0, cv.ROTATE_90_CLOCKWISE, cv.ROTATE_180, cv.ROTATE_90_COUNTERCLOCKWISE][r]);
  }
  return _encode(img);
}

/// isolate에서 실행된다: 촬영 직후 자동 처리 (검출 → 펴기). 결과는 (검출, 편 이미지들).
Future<(Detection, List<Uint8List>)> autoScan(String path) async {
  final det = await detectPage(path);
  return (det, await warpFlat((det.jpg, det.shape)));
}

Uint8List _encode(cv.Mat m) =>
    cv.imencode('.jpg', m, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 92])).$2;

/// isolate에서 실행된다: 저장용 변환. (원본 JPG, 'jpg'|'png', 긴 변 최대 픽셀, JPG 화질)
Future<Uint8List> transcode((Uint8List, String, int?, int) args) async {
  final (jpg, ext, maxSide, quality) = args;
  var img = cv.imdecode(jpg, cv.IMREAD_COLOR);
  if (maxSide != null) {
    final s = maxSide / math.max(img.cols, img.rows);
    if (s < 1) img = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
  }
  return ext == 'png'
      ? cv.imencode('.png', img).$2
      : cv.imencode('.jpg', img, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality])).$2;
}
