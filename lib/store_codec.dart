// 문서 저장 형식(doc.json)의 순수 부분. Flutter·OpenCV·파일·플랫폼 채널에 기대지 않아서 PC에서 `dart test`로 시험한다.
// (dart:convert 만 쓴다. 좌표는 dart:ui 의 Offset/Rect 대신 아래 간단한 값 묶음을 쓴다.)
//
// 여기 있는 함수는 storage.dart 의 Store 가 쓰는 JSON 변환과 '남길 파일' 계산이다.
// 같은 입력이면 예전 Store 코드와 같은 JSON(키 순서까지)과 같은 파일 목록을 낸다.
import 'dart:convert';

/// 좌표 한 점.
typedef Pt = (double, double);

/// 사각형 (왼쪽, 위, 너비, 높이).
typedef Box = (double, double, double, double);

const Pt kZeroPt = (0.0, 0.0);

/// 페이지 윤곽 (PageShape 의 저장용 값).
class ShapeData {
  ShapeData(this.top, this.bottom, this.spread, {this.leftBow = kZeroPt, this.rightBow = kZeroPt});

  final List<Pt> top;
  final List<Pt> bottom;
  final bool spread;
  final Pt leftBow;
  final Pt rightBow;

  ShapeData scaled(double s) => ShapeData(
        [for (final p in top) (p.$1 * s, p.$2 * s)],
        [for (final p in bottom) (p.$1 * s, p.$2 * s)],
        spread,
        leftBow: leftBow == kZeroPt ? kZeroPt : (leftBow.$1 * s, leftBow.$2 * s),
        rightBow: rightBow == kZeroPt ? kZeroPt : (rightBow.$1 * s, rightBow.$2 * s),
      );
}

class StampData {
  StampData(this.rect, this.turns);
  final Box rect;
  final int turns;
}

class OcrLineData {
  OcrLineData(this.text, this.box);
  final String text;
  final Box box;
}

/// 페이지 한 장의 저장용 값. 이미지 바이트는 들어 있지 않다.
class PageData {
  PageData({
    required this.id,
    required this.src,
    required this.w,
    required this.h,
    required this.detShape,
    required this.shape,
    required this.part,
    required this.mode,
    required this.turns,
    this.strength = 1,
    this.cleaned = false,
    this.stamps = const [],
    this.ocr,
    this.hasMask = false,
  });

  final String id;

  /// 원본 사진 번호 (`src_<src>.jpg`)
  final String src;
  final int w;
  final int h;
  final ShapeData detShape;
  final ShapeData shape;
  final int part;

  /// ScanMode 이름
  final String mode;
  final int turns;
  final double strength;
  final bool cleaned;
  final List<StampData> stamps;

  /// null 이면 글자 인식을 하지 않은 것
  final List<OcrLineData>? ocr;

  /// 배경 제거 마스크 파일이 있는지. doc.json 에는 적히지 않고, 남길 파일 계산에만 쓴다.
  final bool hasMask;

  PageData copyWith({int? w, int? h, ShapeData? detShape, ShapeData? shape}) => PageData(
        id: id,
        src: src,
        w: w ?? this.w,
        h: h ?? this.h,
        detShape: detShape ?? this.detShape,
        shape: shape ?? this.shape,
        part: part,
        mode: mode,
        turns: turns,
        strength: strength,
        cleaned: cleaned,
        stamps: stamps,
        ocr: ocr,
        hasMask: hasMask,
      );
}

/// 문서 하나의 저장용 값.
class DocData {
  DocData({
    required this.id,
    required this.name,
    required this.created,
    required this.updated,
    this.folder,
    this.pages = const [],
  });

  final String id;
  final String name;
  final DateTime created;
  final DateTime updated;
  final String? folder;
  final List<PageData> pages;

  DocData copyWith({String? name, DateTime? updated, List<PageData>? pages, String? folder, bool clearFolder = false}) =>
      DocData(
        id: id,
        name: name ?? this.name,
        created: created,
        updated: updated ?? this.updated,
        folder: clearFolder ? null : (folder ?? this.folder),
        pages: pages ?? this.pages,
      );
}

/// 보관함 목록용: 페이지를 읽지 않고 얻는 정보.
class DocHeader {
  DocHeader(this.id, this.name, this.created, this.updated, this.folder, this.pageCount);
  final String id;
  final String name;
  final DateTime created;
  final DateTime updated;
  final String? folder;
  final int pageCount;
}

DocHeader docHeaderFromJson(Map<String, dynamic> j) => DocHeader(
      j['id'],
      j['name'],
      DateTime.parse(j['created']),
      DateTime.parse(j['updated']),
      j['folder'],
      (j['pages'] as List).length,
    );

// ── 문서 → JSON ──

Map<String, dynamic> shapeToJson(ShapeData s) => {
      'top': [for (final p in s.top) [p.$1, p.$2]],
      'bottom': [for (final p in s.bottom) [p.$1, p.$2]],
      'spread': s.spread,
      if (s.leftBow != kZeroPt) 'leftBow': [s.leftBow.$1, s.leftBow.$2],
      if (s.rightBow != kZeroPt) 'rightBow': [s.rightBow.$1, s.rightBow.$2],
    };

Map<String, dynamic> pageToJson(PageData p) => {
      'id': p.id,
      'src': p.src,
      'w': p.w,
      'h': p.h,
      'detShape': shapeToJson(p.detShape),
      'shape': shapeToJson(p.shape),
      'part': p.part,
      'mode': p.mode,
      'turns': p.turns,
      'strength': p.strength,
      'cleaned': p.cleaned,
      'stamps': [
        for (final st in p.stamps)
          {'l': st.rect.$1, 't': st.rect.$2, 'w': st.rect.$3, 'h': st.rect.$4, 'r': st.turns},
      ],
      'ocr': p.ocr == null
          ? null
          : [
              for (final l in p.ocr!) {'t': l.text, 'b': [l.box.$1, l.box.$2, l.box.$3, l.box.$4]},
            ],
    };

Map<String, dynamic> docToJson(DocData d) => {
      'id': d.id,
      'name': d.name,
      'created': d.created.toIso8601String(),
      'updated': d.updated.toIso8601String(),
      'folder': d.folder,
      'pages': [for (final p in d.pages) pageToJson(p)],
    };

String docToJsonString(DocData d) => jsonEncode(docToJson(d));

// ── JSON → 문서 ──

ShapeData shapeFromJson(Map<String, dynamic> j) {
  List<Pt> pts(String k) =>
      [for (final p in j[k] as List) ((p[0] as num).toDouble(), (p[1] as num).toDouble())];
  Pt bow(String k) {
    final v = j[k] as List?;
    return v == null ? kZeroPt : ((v[0] as num).toDouble(), (v[1] as num).toDouble());
  }

  return ShapeData(pts('top'), pts('bottom'), j['spread'], leftBow: bow('leftBow'), rightBow: bow('rightBow'));
}

/// [files] 는 문서 폴더에 있는 파일 이름들. 주어지면 배경 제거 마스크가 있는지 알아낸다.
PageData pageFromJson(Map<String, dynamic> pj, {Set<String>? files}) {
  final id = pj['id'] as String;
  return PageData(
    id: id,
    src: pj['src'] as String,
    w: pj['w'],
    h: pj['h'],
    detShape: shapeFromJson(pj['detShape']),
    shape: shapeFromJson(pj['shape']),
    part: pj['part'],
    mode: pj['mode'] as String,
    turns: pj['turns'],
    strength: (pj['strength'] as num?)?.toDouble() ?? 1,
    cleaned: pj['cleaned'] == true,
    stamps: [
      for (final sj in ((pj['stamps'] as List?) ?? const []))
        StampData((sj['l'].toDouble(), sj['t'].toDouble(), sj['w'].toDouble(), sj['h'].toDouble()), sj['r']),
    ],
    ocr: pj['ocr'] == null
        ? null
        : [
            for (final l in pj['ocr'] as List)
              OcrLineData(l['t'],
                  (l['b'][0].toDouble(), l['b'][1].toDouble(), l['b'][2].toDouble(), l['b'][3].toDouble())),
          ],
    hasMask: files != null && files.contains('mask_$id.png'),
  );
}

DocData docFromJson(Map<String, dynamic> j, {Set<String>? files}) => DocData(
      id: j['id'],
      name: j['name'],
      created: DateTime.parse(j['created']),
      updated: DateTime.parse(j['updated']),
      folder: j['folder'],
      pages: [for (final pj in (j['pages'] as List)) pageFromJson(pj as Map<String, dynamic>, files: files)],
    );

// ── 파일 이름 ──

/// `.../src_<id>.jpg` 경로에서 `<id>`.
String srcIdOfPath(String path) {
  final name = path.split('/').last;
  return name.substring(4, name.length - 4);
}

String srcFileName(String srcId) => 'src_$srcId.jpg';
String flatFileName(String pageId) => 'flat_$pageId.jpg';
String pageFileName(String pageId) => 'page_$pageId.jpg';
String maskFileName(String pageId) => 'mask_$pageId.png';
String stampFileName(String pageId, int i) => 'stamp_${pageId}_$i.png';

const String kDocJson = 'doc.json';
const String kThumbJpg = 'thumb.jpg';

/// 저장 뒤 문서 폴더에 남겨야 하는 파일 이름들. 이 밖의 파일은 저장 때 지워진다.
Set<String> keepFiles(DocData d) {
  final keep = <String>{kDocJson, kThumbJpg};
  for (final p in d.pages) {
    keep.addAll([srcFileName(p.src), flatFileName(p.id), pageFileName(p.id)]);
    for (var i = 0; i < p.stamps.length; i++) {
      keep.add(stampFileName(p.id, i));
    }
    if (p.hasMask) keep.add(maskFileName(p.id));
  }
  return keep;
}

// ── 직접 고치기 (폴더 이동, 원본 줄이기) ──

/// 폴더만 바꾼 문서 (null 이면 폴더에서 뺌).
DocData withFolder(DocData d, String? folder) => d.copyWith(folder: folder, clearFolder: folder == null);

/// 원본을 줄일 배율. 줄일 필요가 없으면(0.95 이상) 1.
double shrinkScale(int w, int h, int maxSide) {
  final s = maxSide / (w > h ? w : h);
  return s >= 0.95 ? 1 : s;
}

/// 원본 번호별 배율 [scales] 를 문서의 크기와 윤곽에 적용한다. 배율이 1이거나 없는 원본의 페이지는 그대로.
DocData scaledDoc(DocData d, Map<String, double> scales) => d.copyWith(pages: [
      for (final p in d.pages)
        if ((scales[p.src] ?? 1) == 1)
          p
        else
          p.copyWith(
            w: (p.w * scales[p.src]!).round(),
            h: (p.h * scales[p.src]!).round(),
            detShape: p.detShape.scaled(scales[p.src]!),
            shape: p.shape.scaled(scales[p.src]!),
          ),
    ]);
