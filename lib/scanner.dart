import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

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
/// 곡선이 양 끝을 잇는 직선에서 가장 멀리 벗어난 정도 (직선 길이 대비)
double _bend(List<Offset> pts) {
  final a = pts.first, b = pts.last, d = b - a, len = d.distance;
  if (len == 0) return 0;
  var m = 0.0;
  for (final p in pts) {
    m = math.max(m, ((p - a).dx * d.dy - (p - a).dy * d.dx).abs() / len);
  }
  return m / len;
}

/// 고해상도(긴 변 1600) 밝기 경사. 모서리 정밀 보정용.
class _Grad {
  _Grad(cv.Mat img, double s800) {
    s = 1600 / math.max(img.cols, img.rows);
    f = s / s800;
    final big = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
    final g = cv.gaussianBlur(cv.cvtColor(big, cv.COLOR_BGR2GRAY), (5, 5), 0);
    w = g.cols;
    h = g.rows;
    gx = Uint8List.fromList(cv.sobel(g, cv.MatType.CV_32F, 1, 0).data).buffer.asFloat32List();
    gy = Uint8List.fromList(cv.sobel(g, cv.MatType.CV_32F, 0, 1).data).buffer.asFloat32List();
    _big = big;
  }

  late final cv.Mat _big;

  /// 흰 종이다운 정도 (밝기 − 3×채도), 처음 쓸 때 계산
  late final Uint8List white = () {
    final lab = Uint8List.fromList(cv.cvtColor(_big, cv.COLOR_BGR2Lab).data);
    final n = w * h, out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      final a = lab[i * 3 + 1] - 128.0, b = lab[i * 3 + 2] - 128.0;
      out[i] = (lab[i * 3] - 3 * math.sqrt(a * a + b * b)).clamp(0, 255).round();
    }
    return Uint8List.fromList(
        cv.gaussianBlur(cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, out), (5, 5), 0).data);
  }();

  double whiteAt(Offset p) {
    final x = p.dx.round(), y = p.dy.round();
    return (x < 0 || y < 0 || x >= w || y >= h) ? 0 : white[y * w + x].toDouble();
  }

  late final double s, f; // f = 800 좌표 → 1600 좌표 배율
  late final int w, h;
  late final Float32List gx, gy;
}

/// 사각형의 네 변을 각각 '안쪽이 밝아지는' 가장 센 경계에 직선으로 맞추고, 교점을 새 모서리로.
/// 많이 움직이면(오검출) 원래 모서리를 둔다.
List<Offset> _refineQuad(_Grad g, List<Offset> q800) {
  final q = [for (final p in q800) p * g.f];
  final c = q.reduce((a, b) => a + b) / 4;
  final lines = <(Offset, Offset)?>[];
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4];
    final d = b - a, len = d.distance;
    final t = d / len;
    var n = Offset(-t.dy, t.dx);
    final mid = (a + b) / 2;
    if ((c - mid).dx * n.dx + (c - mid).dy * n.dy < 0) n = -n;
    final band = math.max(6, (len * 0.04).round());
    final pts = <Offset>[];
    for (var k = 0; k < 40; k++) {
      final p = a + d * (0.08 + 0.84 * k / 39);
      Offset? best;
      var bv = 40.0;
      for (var j = -band; j <= band; j++) {
        final x = (p.dx + n.dx * j).round(), y = (p.dy + n.dy * j).round();
        if (x < 1 || y < 1 || x >= g.w - 1 || y >= g.h - 1) continue;
        final v = g.gx[y * g.w + x] * n.dx + g.gy[y * g.w + x] * n.dy;
        if (v > bv) {
          bv = v;
          best = Offset(x.toDouble(), y.toDouble());
        }
      }
      if (best != null) pts.add(best);
    }
    lines.add(pts.length < 10 ? null : _fitLine(pts));
  }
  final diag = (q[2] - q[0]).distance;
  final out = <Offset>[];
  for (var i = 0; i < 4; i++) {
    final l1 = lines[(i + 3) % 4], l2 = lines[i];
    final p = (l1 == null || l2 == null) ? null : _intersect(l1, l2);
    out.add(p != null && (p - q[i]).distance < 0.06 * diag ? p / g.f : q800[i]);
  }
  return out;
}

/// 점들에 직선 맞춤 (주성분 방향, 튀는 점은 두 번 걸러냄) → (지나는 점, 방향)
(Offset, Offset) _fitLine(List<Offset> pts) {
  var p = pts;
  late Offset m, dir;
  for (var it = 0; it < 3; it++) {
    m = p.reduce((a, b) => a + b) / p.length.toDouble();
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (final q in p) {
      final d = q - m;
      sxx += d.dx * d.dx;
      sxy += d.dx * d.dy;
      syy += d.dy * d.dy;
    }
    final ang = 0.5 * math.atan2(2 * sxy, sxx - syy);
    dir = Offset(math.cos(ang), math.sin(ang));
    if (it == 2) break;
    double dist(Offset q) => ((q - m).dx * dir.dy - (q - m).dy * dir.dx).abs();
    final ds = p.map(dist).toList()..sort();
    final lim = math.max(2.0, ds[ds.length ~/ 2] * 3);
    final kept = p.where((q) => dist(q) < lim).toList();
    if (kept.length < 8) break;
    p = kept;
  }
  return (m, dir);
}

Offset? _intersect((Offset, Offset) l1, (Offset, Offset) l2) {
  final (p, r) = l1;
  final (q, s) = l2;
  final den = r.dx * s.dy - r.dy * s.dx;
  if (den.abs() < 1e-6) return null;
  final t = ((q.dx - p.dx) * s.dy - (q.dy - p.dy) * s.dx) / den;
  return p + r * t;
}

/// 사진 한 장 → 페이지 윤곽들. 사진 속에 문서가 여러 장이면 각각 하나씩 (읽는 순서).
Future<List<Detection>> detectPages(String path) async {
  var img = cv.imread(path, flags: cv.IMREAD_COLOR);
  if (img.isEmpty) throw Exception('읽을 수 없는 사진 형식입니다');
  // 글자가 세로로 누워 있으면(문서를 옆으로 찍음) 90도 돌려서 바로 세운다
  if (_orientScore(cv.rotate(img, cv.ROTATE_90_CLOCKWISE)) > _orientScore(img) * 1.3) {
    img = cv.rotate(img, cv.ROTATE_90_CLOCKWISE);
  }
  final w = img.cols, h = img.rows;
  final (_, jpg) = cv.imencode('.jpg', img, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, 95]));

  // 작게 줄여서 분석 (속도와 잡음 감소)
  final scale = 800 / math.max(w, h);
  final small = cv.resize(img, ((w * scale).round(), (h * scale).round()), interpolation: cv.INTER_AREA);
  final gray = cv.cvtColor(small, cv.COLOR_BGR2GRAY);
  final blur = cv.gaussianBlur(gray, (7, 7), 0);
  final inkAll = cv.adaptiveThreshold(gray, 255, cv.ADAPTIVE_THRESH_MEAN_C, cv.THRESH_BINARY_INV, 25, 15);

  Offset up(Offset p) => Offset((p.dx / scale).clamp(-w * .1, w * 1.1), (p.dy / scale).clamp(-h * .1, h * 1.1));
  Detection toDet(PageShape s) =>
      Detection(jpg, w, h, PageShape(s.top.map(up).toList(), s.bottom.map(up).toList(), s.spread), true);

  // 흰 종이(판)를 모두 찾는다. 2장 이상이면 각각 한 페이지 (책 제본선 찾기는 하지 않음)
  final papers = _findPapers(small);
  // 평평한 문서의 네 변은 고해상도 밝기 경계에 맞춰 다시 그린다 (모서리 정밀 보정)
  _Grad? grad;
  List<Offset> refine(List<Offset> q) => _refineQuad(grad ??= _Grad(img, scale), q);
  if (papers.length >= 2) {
    return [
      for (final (mask, quad) in papers) toDet(_shapeFor(blur, inkAll, mask, refine(quad), findSpine: false)),
    ];
  }

  var paper = papers.isNotEmpty ? papers.first : _paperMask(blur);
  // 사진 안에 통째로 들어온 종이 한 장도 정밀 보정 (가장자리가 사진 밖이거나 휜 책은 제외)
  if (papers.isNotEmpty) {
    final (mask, quad) = paper!;
    final inside = quad.every((p) => p.dx > 3 && p.dy > 3 && p.dx < small.cols - 4 && p.dy < small.rows - 4);
    if (inside && _findSpine(_Gray(blur), _Gray(inkAll), quad[0], quad[1], quad[2], quad[3]) == null) {
      paper = (mask, refine(quad));
    }
  }
  if (paper == null) {
    // 못 찾으면 사진 전체를 페이지로 (사용자가 원하면 나중에 자르기로 조정)
    final c = [Offset.zero, Offset(w - 1.0, 0), Offset(w - 1.0, h - 1.0), Offset(0, h - 1.0)];
    return [Detection(jpg, w, h, PageShape.quad(c, false), false)];
  }
  return [toDet(_shapeFor(blur, inkAll, paper.$1, paper.$2, findSpine: true))];
}

/// 종이 한 장의 윤곽 (작은 이미지 좌표). [findSpine]이면 제본선·잘린 옆 페이지까지 처리.
PageShape _shapeFor(cv.Mat blur, cv.Mat inkAll, cv.Mat blob, List<Offset> quad0, {required bool findSpine}) {
  // 잉크 (글자·음표·선): 이 종이 안만
  var inkM = cv.bitwiseAND(inkAll, blob);
  inkM = cv.morphologyEx(inkM, cv.MORPH_OPEN, cv.getStructuringElement(cv.MORPH_RECT, (2, 2)));

  final g = _Gray(blur), ink = _Gray(inkM), m = _Gray(blob);
  var [tl, tr, br, bl] = quad0;

  // 1) 제본선: 어두운 골짜기 → 없으면 글자 덩어리 사이 여백
  final shadowSpine = findSpine ? _findSpine(g, ink, tl, tr, br, bl) : null;
  final byShadow = shadowSpine != null;
  final spine = findSpine ? (shadowSpine ?? _inkGapSpine(ink, tl, tr, br, bl)) : null;

  // 2) 사진 밖으로 잘린 옆 페이지는 버린다. 양쪽이 비슷하면 양면.
  var spread = false;
  if (spine != null) {
    final (st, sb) = spine;
    final wl = ((st - tl).distance + (sb - bl).distance) / 2;
    final wr = ((tr - st).distance + (br - sb).distance) / 2;
    if (wl < wr * 0.6) {
      tl = st;
      bl = sb;
    } else if (wr < wl * 0.6) {
      tr = st;
      br = sb;
    } else if (byShadow) {
      // 양면은 제본선 그림자가 보일 때만 (2단 문서의 단 사이 여백은 양면이 아니다)
      spread = true;
    }
  }

  // 3) 굴곡: 페이지 안 글자 줄의 휜 모양 (없으면 종이 가장자리를 따라감)
  final lines = _TextLines(inkM);
  (List<Offset>, List<Offset>) straight(Offset tl, Offset tr, Offset br, Offset bl, int n) => (
        [for (var i = 0; i < n; i++) Offset.lerp(tl, tr, i / (n - 1))!],
        [for (var i = 0; i < n; i++) Offset.lerp(bl, br, i / (n - 1))!],
      );
  (List<Offset>, List<Offset>) curves(Offset tl, Offset tr, Offset br, Offset bl, int n) {
    final byText = lines.edges(tl, tr, br, bl, n);
    if (byText != null) {
      // 거의 안 휘었으면 평평한 종이: 정확한 네 모서리로 반듯하게 (글자 줄 위치보다 모서리가 더 정확)
      if (_bend(byText.$1) < 0.015 && _bend(byText.$2) < 0.015) return straight(tl, tr, br, bl, n);
      return byText;
    }
    // 글자 줄이 없을 때 가장자리를 따라 휘게 만드는 것은 책일 때만 (평평한 종이는 액자·그림자에 속기 쉽다)
    if (spine == null) return straight(tl, tr, br, bl, n);
    final center = (tl + tr + br + bl) / 4;
    final pageH = ((bl - tl).distance + (br - tr).distance) / 2;
    return (
      _traceEdge(m, [for (var i = 0; i < n; i++) Offset.lerp(tl, tr, i / (n - 1))!], center, pageH),
      _traceEdge(m, [for (var i = 0; i < n; i++) Offset.lerp(bl, br, i / (n - 1))!], center, pageH),
    );
  }

  if (spread) {
    final (st, sb) = spine!;
    final (lt, lb) = curves(tl, st, sb, bl, kMid + 1);
    final (rt, rb) = curves(st, tr, br, sb, kMid + 1);
    // 두 페이지가 만나는 제본선 점은 평균
    return PageShape(
      [...lt.sublist(0, kMid), (lt.last + rt.first) / 2, ...rt.sublist(1)],
      [...lb.sublist(0, kMid), (lb.last + rb.first) / 2, ...rb.sublist(1)],
      true,
    );
  }
  final (top, bottom) = curves(tl, tr, br, bl, kPts);
  return PageShape(top, bottom, false);
}

/// 흰 종이·판들 찾기: 밝고 무채색인 곳 → 덩어리(글씨 구멍 메움) → 색 띠로 갈라진 조각 합치기
/// → 사각형다움·흰 여백으로 판정. 결과는 (채운 마스크, 네 모서리), 읽는 순서.
List<(cv.Mat, List<Offset>)> _findPapers(cv.Mat small) {
  final sw = small.cols, sh = small.rows, n = sw * sh;
  final lab = Uint8List.fromList(cv.cvtColor(small, cv.COLOR_BGR2Lab).data);
  final white = Uint8List(n);
  for (var i = 0; i < n; i++) {
    final a = lab[i * 3 + 1] - 128.0, b = lab[i * 3 + 2] - 128.0;
    white[i] = (lab[i * 3] - 3 * math.sqrt(a * a + b * b)).clamp(0, 255).round();
  }
  final wm = cv.gaussianBlur(cv.Mat.fromList(sh, sw, cv.MatType.CV_8UC1, white), (5, 5), 0);
  final wd = Uint8List.fromList(wm.data);

  // 문턱: 자동(Otsu)과 '가장 흰 곳의 72%' 중 높은 쪽 (조금 밝은 벽이 섞이지 않게)
  final hist = List<int>.filled(256, 0);
  for (final v in wd) {
    hist[v]++;
  }
  var acc = 0, p99 = 255;
  for (var v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= n * 0.99) {
      p99 = v;
      break;
    }
  }
  final (otsu, _) = cv.threshold(wm, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
  final t = math.max(otsu, 0.72 * p99);
  final (_, raw) = cv.threshold(wm, t, 255, cv.THRESH_BINARY);
  final rawD = Uint8List.fromList(raw.data);
  final closed = cv.morphologyEx(raw, cv.MORPH_CLOSE, cv.getStructuringElement(cv.MORPH_RECT, (5, 5)));
  final (contours, _) = cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

  // 조각들 (점, 범위)
  final parts = <(List<cv.Point>, Rect)>[];
  for (final c in contours) {
    if (cv.contourArea(c) < n * 0.004) continue;
    final pts = c.toList();
    parts.add((pts, _bounds(pts)));
  }
  // 위아래로 나란하고 폭이 거의 같은 조각 = 색 띠로 갈라진 한 장 → 합친다
  var merged = true;
  while (merged) {
    merged = false;
    outer:
    for (var i = 0; i < parts.length; i++) {
      for (var j = 0; j < parts.length; j++) {
        if (i == j) continue;
        final a = parts[i].$2, b = parts[j].$2;
        if (a.top > b.top) continue; // i가 위
        final ov = math.min(a.right, b.right) - math.max(a.left, b.left);
        if (ov < 0.85 * math.max(a.width, b.width)) continue;
        final gap = b.top - a.bottom;
        if (gap < -5 || gap > 0.6 * math.max(a.height, b.height)) continue;
        final pts = [...parts[i].$1, ...parts[j].$1];
        parts[i] = (pts, _bounds(pts));
        parts.removeAt(j);
        merged = true;
        break outer;
      }
    }
  }

  final docs = <(double, cv.Mat, List<Offset>, Offset)>[];
  for (final (pts, _) in parts) {
    final hull = cv.VecPoint.fromMat(cv.convexHull(cv.VecPoint.fromList(pts)));
    final area = cv.contourArea(hull);
    if (area < n * 0.03) continue;
    final rr = cv.minAreaRect(hull).size;
    final rect = area / math.max(rr.width * rr.height, 1);
    final fm = cv.Mat.zeros(sh, sw, cv.MatType.CV_8UC1);
    cv.drawContours(fm, cv.VecVecPoint.fromList([hull.toList()]), 0, cv.Scalar.all(255), thickness: -1);
    final k = math.max(3, (math.sqrt(area) * 0.04).round());
    final inner = cv.erode(fm, cv.getStructuringElement(cv.MORPH_RECT, (k, k)));
    final fd = Uint8List.fromList(fm.data), id = Uint8List.fromList(inner.data);
    var inside = 0, whiteIn = 0, ring = 0, whiteRing = 0;
    for (var i = 0; i < n; i++) {
      if (fd[i] == 0) continue;
      inside++;
      final wt = rawD[i] > 0;
      if (wt) whiteIn++;
      if (id[i] == 0) {
        ring++;
        if (wt) whiteRing++;
      }
    }
    final fill = whiteIn / math.max(inside, 1);
    // 진짜 종이는 테두리 안쪽에 흰 여백이 둘려 있다 (사진을 꽉 채운 종이는 잴 수 없으니 통과)
    final border = ring == 0 ? 1.0 : whiteRing / ring;
    if (rect < 0.8 || fill < 0.4 || border < 0.6) continue;
    final quad = _quadOf(hull);
    docs.add((area, fm, quad, quad.reduce((a, b) => a + b) / 4));
  }
  if (docs.isEmpty) return [];
  final big = docs.map((d) => d.$1).reduce(math.max);
  docs.removeWhere((d) => d.$1 < big * 0.2);
  // 읽는 순서: 위→아래 줄, 줄 안에서 왼→오
  docs.sort((a, b) {
    final ra = (a.$4.dy / (sh * 0.25)).round(), rb = (b.$4.dy / (sh * 0.25)).round();
    return ra != rb ? ra.compareTo(rb) : a.$4.dx.compareTo(b.$4.dx);
  });
  return [for (final d in docs) (d.$2, d.$3)];
}

Rect _bounds(List<cv.Point> pts) {
  var l = pts.first.x, t = pts.first.y, r = l, b = t;
  for (final p in pts) {
    l = math.min(l, p.x);
    t = math.min(t, p.y);
    r = math.max(r, p.x);
    b = math.max(b, p.y);
  }
  return Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble());
}

/// 볼록 껍질을 사각형으로 근사, 안 되면 극점 4개 (좌상·우상·우하·좌하)
List<Offset> _quadOf(cv.VecPoint hull) {
  final peri = cv.arcLength(hull, true);
  for (final k in [0.02, 0.03, 0.05, 0.07, 0.1]) {
    final approx = cv.approxPolyDP(hull, k * peri, true);
    if (approx.length == 4) {
      return orderCorners([for (final p in approx) Offset(p.x.toDouble(), p.y.toDouble())]);
    }
  }
  final pts = [for (final p in hull) Offset(p.x.toDouble(), p.y.toDouble())];
  Offset by(double Function(Offset) f, bool max) => pts.reduce((a, b) => (f(a) > f(b)) == max ? a : b);
  return orderCorners([
    by((p) => p.dx + p.dy, false),
    by((p) => p.dx - p.dy, true),
    by((p) => p.dx + p.dy, true),
    by((p) => p.dx - p.dy, false),
  ]);
}

/// 종이 영역: 종이는 배경보다 밝다 (자동 문턱값). 가장 큰 덩어리와 그 사각형.
(cv.Mat, List<Offset>)? _paperMask(cv.Mat blur) {
  final (_, bin) = cv.threshold(blur, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
  // 글자·그림 구멍을 메우고 잔티를 지운다
  var mask = cv.morphologyEx(bin, cv.MORPH_CLOSE, cv.getStructuringElement(cv.MORPH_RECT, (15, 15)),
      iterations: 2);
  mask = cv.morphologyEx(mask, cv.MORPH_OPEN, cv.getStructuringElement(cv.MORPH_RECT, (9, 9)));
  mask = _cutByLongEdges(blur, mask);
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

  return (blob, _quadOf(cv.VecPoint.fromMat(cv.convexHull(contours[bestIdx]))));
}

/// 종이와 비슷하게 밝은 바닥·벽이 종이에 붙지 않도록, 길게 이어진 가장자리 선으로 끊는다.
/// (짧은 선 = 글자 테두리는 끊지 않음)
cv.Mat _cutByLongEdges(cv.Mat blur, cv.Mat mask) {
  final edges = cv.dilate(cv.canny(blur, 30, 90), cv.getStructuringElement(cv.MORPH_RECT, (3, 3)));
  final labels = cv.Mat.empty(), stats = cv.Mat.empty(), cents = cv.Mat.empty();
  final n = cv.connectedComponentsWithStats(edges, labels, stats, cents, 8, cv.MatType.CV_32S, -1);
  final minLen = math.max(blur.cols, blur.rows) * 0.15;
  final long = List<bool>.filled(n, false);
  for (var i = 1; i < n; i++) {
    long[i] = math.max(stats.at<int>(i, 2), stats.at<int>(i, 3)) > minLen;
  }
  final lab = Uint8List.fromList(labels.data).buffer.asInt32List();
  final out = Uint8List.fromList(mask.data);
  for (var i = 0; i < out.length; i++) {
    if (long[lab[i]]) out[i] = 0;
  }
  final cut = cv.Mat.fromList(mask.rows, mask.cols, cv.MatType.CV_8UC1, out);
  return cv.morphologyEx(cut, cv.MORPH_OPEN, cv.getStructuringElement(cv.MORPH_RECT, (5, 5)));
}

/// 글자 줄이 가로로 놓인 정도 (가로로 길쭉한 잉크 덩어리 길이의 합).
double _orientScore(cv.Mat img) {
  final s = 600 / math.max(img.cols, img.rows);
  final sm = cv.resize(img, ((img.cols * s).round(), (img.rows * s).round()), interpolation: cv.INTER_AREA);
  final ink = cv.adaptiveThreshold(cv.cvtColor(sm, cv.COLOR_BGR2GRAY), 255, cv.ADAPTIVE_THRESH_MEAN_C,
      cv.THRESH_BINARY_INV, 25, 15);
  final k = math.max(9, sm.cols ~/ 30);
  final lm = cv.morphologyEx(ink, cv.MORPH_CLOSE, cv.getStructuringElement(cv.MORPH_RECT, (k, 1)));
  final labels = cv.Mat.empty(), stats = cv.Mat.empty(), cents = cv.Mat.empty();
  final n = cv.connectedComponentsWithStats(lm, labels, stats, cents, 8, cv.MatType.CV_32S, -1);
  var sum = 0.0;
  for (var i = 1; i < n; i++) {
    final bw = stats.at<int>(i, 2), bh = stats.at<int>(i, 3);
    if (bw > 4 * bh && bw > k * 2) sum += bw;
  }
  return sum;
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
/// 선 위 점이 양옆보다 어두운 정도의 '중앙값' → 끊김 없이 이어진 깊은 골짜기만 높게 나온다.
/// 글자가 가로지르는 선(양옆에 동시에 잉크)은 제본선이 아니다. 없으면 null.
(Offset, Offset)? _findSpine(_Gray g, _Gray ink, Offset tl, Offset tr, Offset br, Offset bl) {
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
    if (best <= 0) return 0;
    var hits = 0;
    for (var k = 0; k < 40; k++) {
      final p = Offset.lerp(a, b, 0.1 + 0.8 * k / 39)!;
      bool any(int from, int to) {
        for (var x = from; x <= to; x++) {
          if (ink.on(Offset(p.dx + x, p.dy))) return true;
        }
        return false;
      }

      if (any(-11, -5) && any(5, 11)) hits++;
    }
    return hits / 40 < 0.2 ? best : 0;
  }

  (Offset, Offset)? best;
  var bestScore = 12.0; // 이보다 얕으면 제본선 그림자가 아니다
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

/// 골짜기가 안 보일 때: 글자 덩어리(세로로 본 잉크 분포) 사이의 빈 여백을 제본선으로.
(Offset, Offset)? _inkGapSpine(_Gray ink, Offset tl, Offset tr, Offset br, Offset bl) {
  final w = ink.w, h = ink.h;
  final y0 = (h * .1).round(), y1 = (h * .9).round();
  final col = List<double>.filled(w, 0);
  for (var x = 0; x < w; x++) {
    var c = 0;
    for (var y = y0; y < y1; y++) {
      if (ink.data[y * w + x] > 0) c++;
    }
    col[x] = c / (y1 - y0);
  }
  // 이동 평균으로 부드럽게
  final k = math.max(3, w ~/ 50);
  final sm = List<double>.filled(w, 0);
  for (var x = 0; x < w; x++) {
    var s = 0.0, n = 0;
    for (var j = x - k ~/ 2; j <= x + k ~/ 2; j++) {
      if (j >= 0 && j < w) {
        s += col[j];
        n++;
      }
    }
    sm[x] = s / n;
  }

  // 잉크가 있는 구간들 (좁은 틈은 이어 붙임)
  final runs = <List<int>>[];
  int? start;
  for (var x = 0; x <= w; x++) {
    final on = x < w && sm[x] > 0.02;
    if (on && start == null) start = x;
    if (!on && start != null) {
      if (runs.isNotEmpty && start - runs.last[1] < w * 0.035) {
        runs.last[1] = x;
      } else {
        runs.add([start, x]);
      }
      start = null;
    }
  }
  runs.removeWhere((r) => r[1] - r[0] <= w * 0.03);
  if (runs.length < 2) return null;

  final main = runs.reduce((a, b) => (a[1] - a[0]) >= (b[1] - b[0]) ? a : b);
  final i = runs.indexOf(main);
  final nb = [for (final j in [i - 1, i + 1]) if (j >= 0 && j < runs.length) runs[j]]
      .reduce((a, b) => (a[1] - a[0]) >= (b[1] - b[0]) ? a : b);
  final gx = nb[1] <= main[0] ? (nb[1] + main[0]) / 2 : (main[1] + nb[0]) / 2;

  Offset atX(Offset a, Offset b, double x) {
    final t = b.dx == a.dx ? 0.0 : ((x - a.dx) / (b.dx - a.dx)).clamp(0.0, 1.0);
    return Offset.lerp(a, b, t)!;
  }

  return (atX(tl, tr, gx), atX(bl, br, gx));
}

/// 글자 줄(오선·가사·문장)을 찾아 휜 모양을 재고, 페이지 위·아래 곡선을 만든다.
class _TextLines {
  _TextLines(cv.Mat ink) {
    w = ink.cols;
    h = ink.rows;
    // 가로로 길게 이어 붙여 줄 덩어리로
    final kx = math.max(15, w ~/ 18);
    final k = cv.getStructuringElement(cv.MORPH_RECT, (kx, 1));
    var lm = cv.morphologyEx(ink, cv.MORPH_CLOSE, k);
    lm = cv.morphologyEx(lm, cv.MORPH_OPEN, k);
    final labels = cv.Mat.empty(), stats = cv.Mat.empty(), cents = cv.Mat.empty();
    final n = cv.connectedComponentsWithStats(lm, labels, stats, cents, 8, cv.MatType.CV_32S, -1);
    final lab = Uint8List.fromList(labels.data).buffer.asInt32List();

    for (var i = 1; i < n; i++) {
      final x = stats.at<int>(i, 0), y = stats.at<int>(i, 1);
      final bw = stats.at<int>(i, 2), bh = stats.at<int>(i, 3);
      if (!(bw > w * .12 && bh < h * .05 && bw / math.max(bh, 1) > 8)) continue;
      final pts = <Offset>[];
      for (var cx = x; cx < x + bw; cx += 3) {
        var sum = 0, cnt = 0;
        for (var cy = y; cy < y + bh; cy++) {
          if (lab[cy * w + cx] == i) {
            sum += cy;
            cnt++;
          }
        }
        if (cnt > 0) pts.add(Offset(cx.toDouble(), sum / cnt));
      }
      if (pts.length >= 10) _lines.add(pts);
    }
  }

  late final int w, h;
  final _lines = <List<Offset>>[];

  /// 페이지 사각형 안 줄들로 위·아래 곡선 (각 n점). 쓸 만한 줄이 2개 미만이면 null.
  (List<Offset>, List<Offset>)? edges(Offset tl, Offset tr, Offset br, Offset bl, int n) {
    final topY = (tl.dy + tr.dy) / 2, botY = (bl.dy + br.dy) / 2;
    double rowR(double y) => ((y - topY) / math.max(1, botY - topY)).clamp(0.0, 1.0);
    double pageU(Offset p) {
      final r = rowR(p.dy);
      final lx = Offset.lerp(tl, bl, r)!.dx, rx = Offset.lerp(tr, br, r)!.dx;
      return (p.dx - lx) / math.max(1, rx - lx);
    }

    // 줄마다 y = a·u² + b·u + c 로 맞춤 (u = 페이지 안 가로 위치 0~1)
    final cs = <double>[];
    final ps = <List<double>>[];
    for (final line in _lines) {
      final us = <double>[], ys = <double>[];
      var inside = 0;
      for (final p in line) {
        final u = pageU(p);
        if (u > -0.02 && u < 1.02) {
          inside++;
          us.add(u);
          ys.add(p.dy);
        }
      }
      if (inside < line.length * 0.9) continue; // 제본선을 넘어 옆 페이지와 섞인 줄
      if (us.isEmpty || us.reduce(math.max) - us.reduce(math.min) < 0.5) continue; // 짧은 조각
      final p = _polyfit2(us, ys);
      if (p == null) continue;
      var err = 0.0;
      for (var j = 0; j < us.length; j++) {
        err += (_poly(p, us[j]) - ys[j]).abs();
      }
      if (err / us.length > 3) continue;
      final c = _poly(p, 0.5);
      cs.add(c);
      ps.add([p[0], p[1], p[2] - c]); // 가운데에서 0이 되는 '모양'
    }
    if (cs.length < 2) return null;

    // 모양이 높이(c)에 따라 선형으로 변한다고 보고 맞춘다 (튀는 줄은 빼고 다시)
    var keep = List.filled(cs.length, true);
    late List<List<double>> coef; // [계수][0=절편,1=기울기]
    for (var it = 0; it < 3; it++) {
      coef = [for (var j = 0; j < 3; j++) _linreg(cs, [for (final p in ps) p[j]], keep)];
      final errs = <double>[];
      for (var i = 0; i < cs.length; i++) {
        final pred = [for (var j = 0; j < 3; j++) coef[j][0] + coef[j][1] * cs[i]];
        var e = 0.0;
        for (var t = 0; t <= 8; t++) {
          final u = t / 8;
          e = math.max(e, (_poly(ps[i], u) - _poly(pred, u)).abs());
        }
        errs.add(e);
      }
      final sorted = [...errs]..sort();
      final lim = math.max(2.0, sorted[sorted.length ~/ 2] * 2.5);
      keep = [for (final e in errs) e < lim];
      if (keep.where((k) => k).length < 2) return null;
    }
    final kept = [for (var i = 0; i < cs.length; i++) if (keep[i]) cs[i]];
    final lo = kept.reduce(math.min), hi = kept.reduce(math.max);

    // 높이 Y의 줄 모양으로 한 줄(n점) 만들기. 글자 영역 밖은 가장 바깥 줄 모양 유지.
    List<Offset> row(double y) {
      final yc = y.clamp(lo, hi);
      final s = [for (var j = 0; j < 3; j++) coef[j][0] + coef[j][1] * yc];
      final r = rowR(y);
      final lx = Offset.lerp(tl, bl, r)!.dx, rx = Offset.lerp(tr, br, r)!.dx;
      return [
        for (var i = 0; i < n; i++)
          Offset(lx + (rx - lx) * i / (n - 1), y + _poly(s, i / (n - 1))),
      ];
    }

    return (row(topY), row(botY));
  }
}

double _poly(List<double> p, double u) => (p[0] * u + p[1]) * u + p[2];

/// 2차 최소제곱 맞춤 → [a, b, c] (y = a·u² + b·u + c)
List<double>? _polyfit2(List<double> u, List<double> y) {
  // 정규방정식 (3x3)
  final s = List<double>.filled(5, 0), t = List<double>.filled(3, 0);
  for (var i = 0; i < u.length; i++) {
    var p = 1.0;
    for (var k = 0; k < 5; k++) {
      s[k] += p;
      if (k < 3) t[k] += p * y[i];
      p *= u[i];
    }
  }
  // [s4 s3 s2][a]   [t2]
  // [s3 s2 s1][b] = [t1]
  // [s2 s1 s0][c]   [t0]
  final m = [
    [s[4], s[3], s[2], t[2]],
    [s[3], s[2], s[1], t[1]],
    [s[2], s[1], s[0], t[0]],
  ];
  for (var c = 0; c < 3; c++) {
    var piv = c;
    for (var r = c + 1; r < 3; r++) {
      if (m[r][c].abs() > m[piv][c].abs()) piv = r;
    }
    if (m[piv][c].abs() < 1e-9) return null;
    final tmp = m[c];
    m[c] = m[piv];
    m[piv] = tmp;
    for (var r = 0; r < 3; r++) {
      if (r == c) continue;
      final f = m[r][c] / m[c][c];
      for (var k = c; k < 4; k++) {
        m[r][k] -= f * m[c][k];
      }
    }
  }
  return [m[0][3] / m[0][0], m[1][3] / m[1][1], m[2][3] / m[2][2]];
}

/// 단순 선형 회귀 y = a + b·x (keep인 점만) → [a, b]
List<double> _linreg(List<double> x, List<double> y, List<bool> keep) {
  var n = 0, sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  for (var i = 0; i < x.length; i++) {
    if (!keep[i]) continue;
    n++;
    sx += x[i];
    sy += y[i];
    sxx += x[i] * x[i];
    sxy += x[i] * y[i];
  }
  final d = n * sxx - sx * sx;
  if (n == 0) return [0, 0];
  if (d.abs() < 1e-9) return [sy / n, 0];
  final b = (n * sxy - sx * sy) / d;
  return [(sy - b * sx) / n, b];
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
Future<List<(Detection, List<Uint8List>)>> autoScan(String path) async {
  return [
    for (final det in await detectPages(path)) (det, await warpFlat((det.jpg, det.shape))),
  ];
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

/// isolate에서 실행된다: 사용자가 놓은 모서리를 근처의 실제 종이 모서리에 붙인다.
/// (원본 JPG, 네 모서리 [좌상·우상·우하·좌하] 원본 좌표, 옮긴 모서리 번호들) → 모서리 번호별 붙을 위치
Future<Map<int, Offset>> snapCorners((Uint8List, List<Offset>, List<int>) args) async {
  final (jpg, quad, idxs) = args;
  final img = cv.imdecode(jpg, cv.IMREAD_COLOR);
  if (img.isEmpty) return {};
  final g = _Grad(img, 1.0); // 원본 → 고해상도(긴 변 1600)
  final q = [for (final p in quad) p * g.s];
  final out = <int, Offset>{};
  for (final i in idxs) {
    // 붙은 위치로 다시 맞추기를 몇 번 반복하면 더 정확해진다
    for (var it = 0; it < 3; it++) {
      final p = _snapOne(g, q, i);
      if (p == null) break;
      final moved = (p - q[i]).distance;
      q[i] = p; // 다음 모서리는 붙은 위치 기준으로
      out[i] = p / g.s;
      if (moved < 1.5) break;
    }
  }
  return out;
}

Offset? _snapOne(_Grad g, List<Offset> q, int idx) {
  final c = q[idx];
  final center = q.reduce((a, b) => a + b) / 4;
  final diag = ((q[2] - q[0]).distance + (q[3] - q[1]).distance) / 2;

  // 종이 밝기 기준: 사각형 안쪽(가운데 60%)의 흰 정도 중 밝은 쪽(상위 25%)의 80%
  final samples = <double>[];
  for (var i = 0; i <= 20; i++) {
    for (var j = 0; j <= 20; j++) {
      final top = Offset.lerp(q[0], q[1], i / 20)!, bot = Offset.lerp(q[3], q[2], i / 20)!;
      final p = Offset.lerp(top, bot, j / 20)!;
      samples.add(g.whiteAt(center + (p - center) * 0.6));
    }
  }
  samples.sort();
  final paperT = 0.8 * samples[(samples.length * 0.75).floor()];

  // 이 모서리에서 이웃 모서리까지 변 전체를 보며 실제 테두리를 찾아 직선으로
  (Offset, Offset)? edgeNear(Offset other) {
    final d = other - c, len = d.distance;
    if (len < 10) return null;
    final t = d / len;
    var n = Offset(-t.dy, t.dx);
    final mid = c + d * 0.3;
    if ((center - mid).dx * n.dx + (center - mid).dy * n.dy < 0) n = -n;
    final band = math.max(14, (diag * 0.10).round()); // 대충 놓아도 찾도록 넓게
    final pts = <Offset>[];
    for (var k = 0; k < 40; k++) {
      final p = c + d * (0.03 + 0.92 * k / 39);
      // 바깥 → 안쪽으로 걸으며 '안쪽은 종이처럼 희고 바깥은 종이가 아닌' 첫 경계 = 종이 테두리
      // (안쪽 큰 글씨, 바깥 벽 타일 줄눈, 옆에 붙은 다른 종이에 속지 않게)
      final prof = [for (var j = -band - 8; j <= band + 8; j++) g.whiteAt(p + n * j.toDouble())];
      double mean(int a, int b) {
        var s = 0.0;
        for (var i = a; i < b; i++) {
          s += prof[i];
        }
        return s / (b - a);
      }

      for (var i = 8; i < prof.length - 8; i++) {
        final inside = mean(i + 2, i + 7), outside = mean(i - 6, i - 1);
        if (inside > paperT && outside < paperT - 25 && inside - outside > 35) {
          pts.add(p + n * (i - band - 8).toDouble());
          break;
        }
      }
    }
    return pts.length < 10 ? null : _fitLine(pts);
  }

  final l1 = edgeNear(q[(idx + 3) % 4]), l2 = edgeNear(q[(idx + 1) % 4]);
  Offset? p;
  if (l1 != null && l2 != null) {
    p = _intersect(l1, l2);
  } else if (l1 != null || l2 != null) {
    // 한 변만 찾았으면 그 선 위의 가장 가까운 점으로
    final (m, dir) = (l1 ?? l2)!;
    final along = (c - m).dx * dir.dx + (c - m).dy * dir.dy;
    p = m + dir * along;
  }
  if (p == null || (p - c).distance > diag * 0.15) return null;
  return p;
}
