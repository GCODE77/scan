import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ocr.dart';
import 'scanner.dart';
import 'signature.dart';
import 'store_codec.dart';

/// 문서 하나 (스캔한 페이지 묶음).
class ScanDoc {
  ScanDoc({required this.id, required this.name, required this.created, required this.updated});

  final String id;
  String name;
  final DateTime created;
  DateTime updated;

  /// 열었을 때만 채워진다 ([Store.load])
  List<ScanPage> pages = [];

  /// 보관함 목록용 (열지 않아도 아는 정보)
  int pageCount = 0;
  String? thumbPath;

  /// 폴더 이름 (null이면 폴더 없음)
  String? folder;
}

/// 기기 안(앱 전용 폴더)에 문서를 보관한다.
///
/// `docs/<문서id>/doc.json`        문서 정보와 페이지 목록
///              `src_<id>.jpg`    촬영 원본 (자르기를 다시 할 때 필요)
///              `flat_<id>.jpg`    편 이미지 (필터 적용 전)
///              `page_<id>.jpg`    최종 이미지
///              thumb.jpg        보관함 썸네일
///
/// doc.json 의 JSON 변환과 '남길 파일' 계산은 순수 함수인 store_codec.dart 에 있다.
class Store {
  static Directory? _root;

  static Future<Directory> _docsDir() async =>
      _root ??= await Directory('${(await getApplicationDocumentsDirectory()).path}/docs')
          .create(recursive: true);

  static Future<Directory> _dir(String id) async =>
      Directory('${(await _docsDir()).path}/$id').create(recursive: true);

  /// 최근 수정 순 문서 목록 (페이지는 읽지 않음)
  static Future<List<ScanDoc>> list() async {
    final root = await _docsDir();
    final docs = <ScanDoc>[];
    await for (final e in root.list()) {
      final f = File('${e.path}/$kDocJson');
      if (e is! Directory || !await f.exists()) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final d = _docFrom(j);
        final thumb = File('${e.path}/$kThumbJpg');
        if (await thumb.exists()) d.thumbPath = thumb.path;
        docs.add(d);
      } catch (e) {
        debugPrint('문서 읽기 실패: $e');
      }
    }
    docs.sort((a, b) => b.updated.compareTo(a.updated));
    return docs;
  }

  static ScanDoc newDoc() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return ScanDoc(
      id: newId(),
      name: '스캔 ${now.year}.${two(now.month)}.${two(now.day)} ${two(now.hour)}:${two(now.minute)}',
      created: now,
      updated: now,
    );
  }

  static ScanDoc _docFrom(Map<String, dynamic> j) {
    final h = docHeaderFromJson(j);
    return ScanDoc(id: h.id, name: h.name, created: h.created, updated: h.updated)
      ..folder = h.folder
      ..pageCount = h.pageCount;
  }

  /// 문서의 페이지들을 읽어 온다.
  static Future<void> load(ScanDoc doc) async {
    final dir = await _dir(doc.id);
    final j = jsonDecode(await File('${dir.path}/$kDocJson').readAsString()) as Map<String, dynamic>;
    final data = docFromJson(j);
    final dets = <String, Detection>{}; // 같은 원본에서 나온 페이지(양면)는 같은 객체를 쓴다
    final pages = <ScanPage>[];
    for (final pd in data.pages) {
      final det = dets[pd.src] ??=
          Detection.stored('${dir.path}/${srcFileName(pd.src)}', pd.w, pd.h, _shapeFrom(pd.detShape));
      final id = pd.id;
      final flat = await File('${dir.path}/${flatFileName(id)}').readAsBytes();
      final p = ScanPage(det: det, shape: _shapeFrom(pd.shape), part: pd.part, flat: flat, id: id)
        ..mode = ScanMode.values.byName(pd.mode)
        ..quarterTurns = pd.turns
        ..strength = pd.strength
        ..cleaned = pd.cleaned;
      final pageFile = File('${dir.path}/${pageFileName(id)}');
      if (await pageFile.exists()) p.jpg = await pageFile.readAsBytes();
      final maskFile = File('${dir.path}/${maskFileName(id)}');
      if (await maskFile.exists()) {
        p.cutMask = await maskFile.readAsBytes();
        _savedMask[p] = p.cutMask;
      }
      for (final (i, sd) in pd.stamps.indexed) {
        final f = File('${dir.path}/${stampFileName(id, i)}');
        if (!await f.exists()) continue;
        p.stamps.add(Stamp(await f.readAsBytes(), Rect.fromLTWH(sd.rect.$1, sd.rect.$2, sd.rect.$3, sd.rect.$4),
            turns: sd.turns));
      }
      if (pd.ocr != null) {
        p.ocr = OcrResult([
          for (final l in pd.ocr!) OcrLine(l.text, Rect.fromLTWH(l.box.$1, l.box.$2, l.box.$3, l.box.$4)),
        ]);
      }
      _saved[p] = (p.flat, p.jpg);
      pages.add(p);
    }
    doc.pages = pages;
    doc.pageCount = pages.length;
  }

  /// 마지막으로 파일에 쓴 이미지 (바뀐 것만 다시 쓰기 위해)
  static final _saved = Expando<(Uint8List, Uint8List)>();
  static final _savedMask = Expando<Uint8List>();

  /// 같은 문서의 저장·폴더 이동·원본 줄이기가 겹치지 않도록 줄 세운다.
  static final _queues = <String, Future<void>>{};

  /// 문서별 줄에 일을 세운다. 앞 일이 실패해도 뒷일은 돈다. 돌려주는 값은 이 일 자신의 결과.
  static Future<T> _enqueue<T>(String id, Future<T> Function() task) {
    final prev = _queues[id] ?? Future.value();
    final run = prev.catchError((_) {}).then((_) => task());
    _queues[id] = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<void> save(ScanDoc doc) => _enqueue(doc.id, () => _save(doc));

  /// 임시 파일에 쓰고 바꿔치기 (도중에 꺼져도 파일이 깨지지 않게)
  static Future<void> _writeAtomic(File target, List<int> bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  static Future<void> _writeJson(File target, DocData data) =>
      _writeAtomic(target, utf8.encode(docToJsonString(data)));

  static Future<void> _save(ScanDoc doc) async {
    final dir = await _dir(doc.id);
    doc.updated = DateTime.now();
    doc.pageCount = doc.pages.length;
    final srcIds = <String>[];

    for (final p in doc.pages) {
      final det = p.det;
      final srcId = det.path == null ? p.id : srcIdOfPath(det.path!);
      final srcName = srcFileName(srcId);
      if (det.path == null) {
        await File('${dir.path}/$srcName').writeAsBytes(det.jpg);
        det.storedAt('${dir.path}/$srcName');
      } else if (!det.path!.startsWith(dir.path)) {
        // 다른 곳(예: 다른 문서)의 원본이면 복사
        await File(det.path!).copy('${dir.path}/$srcName');
        det.storedAt('${dir.path}/$srcName');
      }
      srcIds.add(srcId);
      for (final (i, st) in p.stamps.indexed) {
        await File('${dir.path}/${stampFileName(p.id, i)}').writeAsBytes(st.png);
      }
      final last = _saved[p];
      if (last == null || !identical(last.$1, p.flat)) {
        await File('${dir.path}/${flatFileName(p.id)}').writeAsBytes(p.flat);
      }
      if (last == null || !identical(last.$2, p.jpg)) {
        await File('${dir.path}/${pageFileName(p.id)}').writeAsBytes(p.jpg);
      }
      _saved[p] = (p.flat, p.jpg);
      // 배경 제거 마스크
      if (p.cutMask != null && !identical(_savedMask[p], p.cutMask)) {
        await File('${dir.path}/${maskFileName(p.id)}').writeAsBytes(p.cutMask!);
      }
      _savedMask[p] = p.cutMask;
    }

    if (doc.pages.isNotEmpty) {
      final thumb = await compute(transcode, (doc.pages.first.jpg, 'jpg', 480, 80));
      await File('${dir.path}/$kThumbJpg').writeAsBytes(thumb);
      doc.thumbPath = '${dir.path}/$kThumbJpg';
    }

    final data = _toData(doc, srcIds);
    await _writeJson(File('${dir.path}/$kDocJson'), data);

    // 더 이상 쓰지 않는 파일 정리
    final keep = keepFiles(data);
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is File && !keep.contains(name)) await f.delete();
    }
  }

  /// 메모리의 문서를 저장용 값으로 ([srcIds]는 페이지마다의 원본 번호).
  static DocData _toData(ScanDoc doc, List<String> srcIds) => DocData(
        id: doc.id,
        name: doc.name,
        created: doc.created,
        updated: doc.updated,
        folder: doc.folder,
        pages: [
          for (final (i, p) in doc.pages.indexed)
            PageData(
              id: p.id,
              src: srcIds[i],
              w: p.det.width,
              h: p.det.height,
              detShape: _shapeTo(p.det.shape),
              shape: _shapeTo(p.shape),
              part: p.part,
              mode: p.mode.name,
              turns: p.quarterTurns,
              strength: p.strength,
              cleaned: p.cleaned,
              stamps: [
                for (final st in p.stamps)
                  StampData((st.rect.left, st.rect.top, st.rect.width, st.rect.height), st.turns),
              ],
              ocr: p.ocr == null
                  ? null
                  : [
                      for (final l in p.ocr!.lines)
                        OcrLineData(l.text, (l.box.left, l.box.top, l.box.width, l.box.height)),
                    ],
              hasMask: p.cutMask != null,
            ),
        ],
      );

  static Future<void> delete(ScanDoc doc) async {
    await _queues[doc.id];
    final dir = Directory('${(await _docsDir()).path}/${doc.id}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static Future<void> rename(ScanDoc doc, String name) async {
    doc.name = name;
    if (doc.pages.isEmpty && doc.pageCount > 0) await load(doc);
    await save(doc);
  }

  static ShapeData _shapeTo(PageShape s) => ShapeData(
        [for (final p in s.top) (p.dx, p.dy)],
        [for (final p in s.bottom) (p.dx, p.dy)],
        s.spread,
        leftBow: (s.leftBow.dx, s.leftBow.dy),
        rightBow: (s.rightBow.dx, s.rightBow.dy),
      );

  static PageShape _shapeFrom(ShapeData s) => PageShape(
        [for (final p in s.top) Offset(p.$1, p.$2)],
        [for (final p in s.bottom) Offset(p.$1, p.$2)],
        s.spread,
        leftBow: Offset(s.leftBow.$1, s.leftBow.$2),
        rightBow: Offset(s.rightBow.$1, s.rightBow.$2),
      );

  // ── 폴더 ──

  /// 문서를 폴더로 옮긴다 (null이면 폴더에서 빼기). 페이지를 읽지 않고 정보만 고친다.
  /// 저장 줄에 서고, 같은 순수 함수로 JSON을 만들어 임시 파일로 바꿔치기한다.
  static Future<void> setFolder(ScanDoc doc, String? folder) => _enqueue(doc.id, () async {
        final f = File('${(await _docsDir()).path}/${doc.id}/$kDocJson');
        if (!await f.exists()) return;
        final data = docFromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        await _writeJson(f, withFolder(data, folder));
        doc.folder = folder;
      });

  // ── 저장 공간 ──

  /// 문서 하나가 차지하는 바이트
  static Future<int> sizeOf(ScanDoc doc) async {
    final dir = Directory('${(await _docsDir()).path}/${doc.id}');
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final f in dir.list()) {
      if (f is File) n += await f.length();
    }
    return n;
  }

  /// 전체 보관함 크기
  static Future<int> totalSize() async {
    var n = 0;
    await for (final e in (await _docsDir()).list(recursive: true)) {
      if (e is File) n += await e.length();
    }
    return n;
  }

  /// 원본 사진 줄이기: 촬영 원본을 긴 변 [maxSide]px로 줄여 저장 공간을 아낀다.
  /// 자르기(윤곽 수정)는 계속 되지만 다시 펼 때 화질이 조금 낮아질 수 있다. 줄인 바이트를 돌려준다.
  static Future<int> shrinkOriginals(ScanDoc doc, {int maxSide = 2000}) => _enqueue(doc.id, () async {
        final dir = '${(await _docsDir()).path}/${doc.id}';
        final jf = File('$dir/$kDocJson');
        if (!await jf.exists()) return 0;
        final data = docFromJson(jsonDecode(await jf.readAsString()) as Map<String, dynamic>);
        final scales = <String, double>{}; // 원본 id → 줄인 배율
        var saved = 0;
        for (final p in data.pages) {
          if (scales.containsKey(p.src)) continue;
          final f = File('$dir/${srcFileName(p.src)}');
          final s = shrinkScale(p.w, p.h, maxSide);
          if (s == 1 || !await f.exists()) {
            scales[p.src] = 1;
          } else {
            final before = await f.length();
            final small = await compute(transcode, (await f.readAsBytes(), 'jpg', maxSide, 85));
            await _writeAtomic(f, small);
            saved += before - small.length;
            scales[p.src] = s;
          }
        }
        await _writeJson(jf, scaledDoc(data, scales));
        return saved;
      });
}
