import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ocr.dart';
import 'scanner.dart';
import 'signature.dart';

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
}

/// 기기 안(앱 전용 폴더)에 문서를 보관한다.
///
/// `docs/<문서id>/doc.json`        문서 정보와 페이지 목록
///              `src_<id>.jpg`    촬영 원본 (자르기를 다시 할 때 필요)
///              `flat_<id>.jpg`    편 이미지 (필터 적용 전)
///              `page_<id>.jpg`    최종 이미지
///              thumb.jpg        보관함 썸네일
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
      final f = File('${e.path}/doc.json');
      if (e is! Directory || !await f.exists()) continue;
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final d = _docFrom(j)..pageCount = (j['pages'] as List).length;
        final thumb = File('${e.path}/thumb.jpg');
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

  static ScanDoc _docFrom(Map<String, dynamic> j) => ScanDoc(
        id: j['id'],
        name: j['name'],
        created: DateTime.parse(j['created']),
        updated: DateTime.parse(j['updated']),
      );

  /// 문서의 페이지들을 읽어 온다.
  static Future<void> load(ScanDoc doc) async {
    final dir = await _dir(doc.id);
    final j = jsonDecode(await File('${dir.path}/doc.json').readAsString());
    final dets = <String, Detection>{}; // 같은 원본에서 나온 페이지(양면)는 같은 객체를 쓴다
    final pages = <ScanPage>[];
    for (final pj in j['pages'] as List) {
      final src = pj['src'] as String;
      final det = dets[src] ??= Detection.stored(
          '${dir.path}/src_$src.jpg', pj['w'], pj['h'], _shapeFrom(pj['detShape']));
      final id = pj['id'] as String;
      final flat = await File('${dir.path}/flat_$id.jpg').readAsBytes();
      final p = ScanPage(det: det, shape: _shapeFrom(pj['shape']), part: pj['part'], flat: flat, id: id)
        ..mode = ScanMode.values.byName(pj['mode'])
        ..quarterTurns = pj['turns']
        ..strength = (pj['strength'] as num?)?.toDouble() ?? 1;
      final pageFile = File('${dir.path}/page_$id.jpg');
      if (await pageFile.exists()) p.jpg = await pageFile.readAsBytes();
      for (final (i, sj) in ((pj['stamps'] as List?) ?? const []).indexed) {
        final f = File('${dir.path}/stamp_${id}_$i.png');
        if (!await f.exists()) continue;
        p.stamps.add(Stamp(await f.readAsBytes(),
            Rect.fromLTWH(sj['l'].toDouble(), sj['t'].toDouble(), sj['w'].toDouble(), sj['h'].toDouble()),
            turns: sj['r']));
      }
      if (pj['ocr'] != null) {
        p.ocr = OcrResult([
          for (final l in pj['ocr'] as List)
            OcrLine(l['t'], Rect.fromLTWH(l['b'][0].toDouble(), l['b'][1].toDouble(),
                l['b'][2].toDouble(), l['b'][3].toDouble())),
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

  /// 같은 문서의 저장이 겹치지 않도록 줄 세운다.
  static final _queues = <String, Future<void>>{};

  static Future<void> save(ScanDoc doc) =>
      _queues[doc.id] = (_queues[doc.id] ?? Future.value()).then((_) => _save(doc));

  static Future<void> _save(ScanDoc doc) async {
    final dir = await _dir(doc.id);
    doc.updated = DateTime.now();
    doc.pageCount = doc.pages.length;
    final keep = <String>{'doc.json', 'thumb.jpg'};

    for (final p in doc.pages) {
      final det = p.det;
      final srcId = det.path == null ? p.id : _srcIdOf(det.path!);
      final srcName = 'src_$srcId.jpg';
      if (det.path == null) {
        await File('${dir.path}/$srcName').writeAsBytes(det.jpg);
        det.storedAt('${dir.path}/$srcName');
      } else if (!det.path!.startsWith(dir.path)) {
        // 다른 곳(예: 다른 문서)의 원본이면 복사
        await File(det.path!).copy('${dir.path}/$srcName');
        det.storedAt('${dir.path}/$srcName');
      }
      keep.addAll([srcName, 'flat_${p.id}.jpg', 'page_${p.id}.jpg']);
      for (final (i, st) in p.stamps.indexed) {
        final name = 'stamp_${p.id}_$i.png';
        keep.add(name);
        await File('${dir.path}/$name').writeAsBytes(st.png);
      }
      final last = _saved[p];
      if (last == null || !identical(last.$1, p.flat)) {
        await File('${dir.path}/flat_${p.id}.jpg').writeAsBytes(p.flat);
      }
      if (last == null || !identical(last.$2, p.jpg)) {
        await File('${dir.path}/page_${p.id}.jpg').writeAsBytes(p.jpg);
      }
      _saved[p] = (p.flat, p.jpg);
    }

    if (doc.pages.isNotEmpty) {
      final thumb = await compute(transcode, (doc.pages.first.jpg, 'jpg', 480, 80));
      await File('${dir.path}/thumb.jpg').writeAsBytes(thumb);
      doc.thumbPath = '${dir.path}/thumb.jpg';
    }

    final json = {
      'id': doc.id,
      'name': doc.name,
      'created': doc.created.toIso8601String(),
      'updated': doc.updated.toIso8601String(),
      'pages': [
        for (final p in doc.pages)
          {
            'id': p.id,
            'src': _srcIdOf(p.det.path!),
            'w': p.det.width,
            'h': p.det.height,
            'detShape': _shapeTo(p.det.shape),
            'shape': _shapeTo(p.shape),
            'part': p.part,
            'mode': p.mode.name,
            'turns': p.quarterTurns,
            'strength': p.strength,
            'stamps': [
              for (final st in p.stamps)
                {'l': st.rect.left, 't': st.rect.top, 'w': st.rect.width, 'h': st.rect.height, 'r': st.turns},
            ],
            'ocr': p.ocr == null
                ? null
                : [
                    for (final l in p.ocr!.lines)
                      {
                        't': l.text,
                        'b': [l.box.left, l.box.top, l.box.width, l.box.height],
                      },
                  ],
          },
      ],
    };
    // 임시 파일에 쓰고 바꿔치기 (도중에 꺼져도 문서가 깨지지 않게)
    final tmp = File('${dir.path}/doc.json.tmp');
    await tmp.writeAsString(jsonEncode(json));
    await tmp.rename('${dir.path}/doc.json');

    // 더 이상 쓰지 않는 파일 정리
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is File && !keep.contains(name)) await f.delete();
    }
  }

  static String _srcIdOf(String path) {
    final name = path.split('/').last;
    return name.substring(4, name.length - 4); // src_<id>.jpg
  }

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

  static Map<String, dynamic> _shapeTo(PageShape s) => {
        'top': [for (final p in s.top) [p.dx, p.dy]],
        'bottom': [for (final p in s.bottom) [p.dx, p.dy]],
        'spread': s.spread,
      };

  static PageShape _shapeFrom(Map<String, dynamic> j) {
    List<Offset> pts(String k) =>
        [for (final p in j[k] as List) Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())];
    return PageShape(pts('top'), pts('bottom'), j['spread']);
  }
}
