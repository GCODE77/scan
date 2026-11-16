// 백업·복원의 순수 부분. Flutter·OpenCV·플랫폼 채널에 기대지 않아서 PC에서 `dart run`으로 시험한다.
// (dart:io 와 archive 패키지만 쓴다.)
//
// ZIP 구조
//   bookscan_backup.json              {format, app, created, docCount}
//   docs/<문서id>/doc.json, src_*.jpg, flat_*.jpg, page_*.jpg, mask_*.png, stamp_*.png, thumb.jpg
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

/// 이 앱이 만들고 읽을 수 있는 백업 형식 번호.
const int kBackupFormat = 1;

/// ZIP 맨 위의 형식 번호 파일 이름.
const String kBackupMarker = 'bookscan_backup.json';

/// 사람에게 보여 줄 수 있는 한국어 문장을 담은 오류.
class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 백업에 넣을 파일 하나.
class BackupFile {
  BackupFile(this.zipName, this.path, this.size);
  final String zipName;
  final String path;
  final int size;
}

/// 백업에 넣을 문서 하나.
class BackupDoc {
  BackupDoc(this.id, this.files);
  final String id;
  final List<BackupFile> files;
}

final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _fileRe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,120}$');

bool isValidDocId(String id) => _idRe.hasMatch(id);

/// ZIP 안 이름이 `docs/<id>/<파일>` 형태인지 엄격하게 확인한다. 아니면 null.
/// `..`, 절대 경로, 역슬래시, 드라이브 문자, 하위 폴더는 모두 거부한다(경로 탈출 방어).
({String id, String file})? parseEntryName(String name) {
  if (name.contains('\\') || name.contains(':') || name.contains('\u0000')) return null;
  final parts = name.split('/');
  if (parts.length != 3 || parts[0] != 'docs') return null;
  final id = parts[1], file = parts[2];
  if (!_idRe.hasMatch(id) || !_fileRe.hasMatch(file) || file.contains('..')) return null;
  if (file.endsWith('.tmp')) return null;
  return (id: id, file: file);
}

/// 문서 폴더들을 읽어 백업에 넣을 파일 목록을 만든다.
/// doc.json 이 없는 폴더나 없는 id 는 건너뛴다. 하위 폴더와 `.tmp` 파일은 넣지 않는다.
List<BackupDoc> planBackup(String docsRoot, Iterable<String> docIds) {
  final docs = <BackupDoc>[];
  for (final id in docIds) {
    if (!isValidDocId(id)) continue;
    final dir = Directory('$docsRoot/$id');
    if (!dir.existsSync() || !File('${dir.path}/doc.json').existsSync()) continue;
    final files = <BackupFile>[];
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name.endsWith('.tmp') || !_fileRe.hasMatch(name)) continue;
      files.add(BackupFile('docs/$id/$name', e.path, e.lengthSync()));
    }
    files.sort((a, b) => a.zipName.compareTo(b.zipName));
    docs.add(BackupDoc(id, files));
  }
  return docs;
}

/// ZIP 안에 들어갈 이름 전체 (형식 번호 파일 포함). 시험과 화면 표시용.
List<String> backupEntryNames(List<BackupDoc> docs) =>
    [kBackupMarker, for (final d in docs) for (final f in d.files) f.zipName];

/// 예상 크기(바이트). 사진은 압축하지 않고 담으므로 파일 크기의 합과 거의 같다.
int estimateBackupSize(List<BackupDoc> docs) {
  var n = 0;
  for (final d in docs) {
    for (final f in d.files) {
      n += f.size;
    }
  }
  return n;
}

/// 남은 공간이 예상 크기의 1.1배 이상이어야 시작한다.
bool hasEnoughSpace(int freeBytes, int needBytes, {double factor = 1.1}) => freeBytes >= needBytes * factor;

String backupMarkerJson({required String appVersion, required DateTime created, required int docCount}) =>
    jsonEncode({
      'format': kBackupFormat,
      'app': appVersion,
      'created': created.toIso8601String(),
      'docCount': docCount,
    });

/// 백업 ZIP 을 만든다. 파일을 하나씩 스트림으로 읽어 쓰므로 전체를 메모리에 올리지 않는다.
/// 사진·PNG 는 압축하지 않고(STORE) doc.json 만 압축한다.
/// [onDoc] 은 문서를 시작할 때 (지금까지 시작한 수, 전체 수)로 불린다.
void writeBackupZip({
  required String zipPath,
  required List<BackupDoc> docs,
  required String appVersion,
  DateTime? created,
  void Function(int index, int total)? onDoc,
}) {
  final enc = ZipFileEncoder();
  enc.create(zipPath);
  try {
    final marker = ArchiveFile.string(
        kBackupMarker,
        backupMarkerJson(
            appVersion: appVersion, created: created ?? DateTime.now(), docCount: docs.length));
    enc.addArchiveFile(marker);
    for (final (i, d) in docs.indexed) {
      onDoc?.call(i + 1, docs.length);
      for (final f in d.files) {
        final stream = InputFileStream(f.path);
        final af = ArchiveFile.stream(f.zipName, stream);
        if (!f.zipName.endsWith('.json')) af.compression = CompressionType.none;
        af.lastModTime = File(f.path).lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
        try {
          enc.addArchiveFile(af);
        } finally {
          stream.closeSync();
        }
      }
    }
  } finally {
    enc.closeSync();
  }
}

/// 가져오기 전에 보여 줄 백업 문서 정보.
class BackupDocInfo {
  BackupDocInfo(this.id, this.name, this.pageCount, this.fileCount);
  final String id;
  final String name;
  final int pageCount;
  final int fileCount;
}

class BackupInfo {
  BackupInfo(this.format, this.app, this.docs, this.ignoredEntries);
  final int format;
  final String app;
  final List<BackupDocInfo> docs;

  /// 이름이 안전하지 않거나 모양이 달라 읽지 않은 항목 수
  final int ignoredEntries;
}

/// ZIP 을 열어 형식 번호와 문서 목록만 읽는다(사진은 읽지 않는다).
/// 백업 파일이 아니거나 형식 번호가 앱이 아는 것보다 높으면 [BackupException].
BackupInfo inspectBackup(String zipPath) {
  InputFileStream? input;
  try {
    input = InputFileStream(zipPath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (_) {
      throw BackupException('백업 파일이 아니거나 손상된 파일입니다.');
    }
    final marker = archive.find(kBackupMarker);
    if (marker == null || !marker.isFile) {
      throw BackupException('북스캔 백업 파일이 아닙니다.');
    }
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(utf8.decode(marker.readBytes() ?? const [])) as Map<String, dynamic>;
    } catch (_) {
      throw BackupException('백업 파일의 형식 정보를 읽지 못했습니다.');
    }
    final format = m['format'];
    if (format is! int) throw BackupException('백업 파일의 형식 정보를 읽지 못했습니다.');
    if (format > kBackupFormat) {
      throw BackupException('이 백업은 더 새로운 북스캔에서 만들었습니다. 앱을 먼저 업데이트하세요.');
    }
    final counts = <String, int>{};
    final jsons = <String, ArchiveFile>{};
    var ignored = 0;
    for (final f in archive) {
      if (!f.isFile || f.name == kBackupMarker) continue;
      final p = parseEntryName(f.name);
      if (p == null) {
        ignored++;
        continue;
      }
      counts[p.id] = (counts[p.id] ?? 0) + 1;
      if (p.file == 'doc.json') jsons[p.id] = f;
    }
    final docs = <BackupDocInfo>[];
    for (final e in jsons.entries) {
      var name = e.key;
      var pages = 0;
      try {
        final j = jsonDecode(utf8.decode(e.value.readBytes() ?? const [])) as Map<String, dynamic>;
        if (j['id'] != e.key) {
          ignored++;
          continue; // 폴더 이름과 문서 id 가 다르면 가져오지 않는다
        }
        name = (j['name'] as String?) ?? name;
        pages = (j['pages'] as List).length;
      } catch (_) {
        ignored++;
        continue;
      }
      docs.add(BackupDocInfo(e.key, name, pages, counts[e.key] ?? 0));
    }
    docs.sort((a, b) => a.id.compareTo(b.id));
    return BackupInfo(format, (m['app'] as String?) ?? '', docs, ignored);
  } finally {
    input?.closeSync();
  }
}

/// 같은 문서 id 가 이미 있을 때의 처리.
enum DuplicatePolicy { skip, copy }

/// 복사본으로 가져올 때 doc.json 의 문서 id 를 바꾸고 이름 뒤에 표시를 붙인다.
/// 파일 이름(src_·flat_·page_·mask_·stamp_)은 페이지 id 로만 이루어져 있어 문서 id 를 담지 않으므로 그대로 둔다.
/// 그 밖의 필드는 건드리지 않는다.
String rewriteDocJson(String json, String newId, {String suffix = ' (복사본)'}) {
  final j = jsonDecode(json) as Map<String, dynamic>;
  j['id'] = newId;
  j['name'] = '${j['name'] ?? ''}$suffix';
  return jsonEncode(j);
}

class ImportResult {
  int imported = 0; // 새로 가져온 문서
  int copied = 0; // 복사본으로 가져온 문서
  int skipped = 0; // 건너뛴 문서
  final List<String> failed = []; // 실패한 문서 id
  int get total => imported + copied;
}

/// ZIP 의 문서들을 [docsRoot] 로 푼다. 문서마다 `<id>.importing` 폴더에 풀고 doc.json 을 마지막에 써서
/// 이름을 바꾸므로, 도중에 끊겨도 반쯤 풀린 문서가 보관함에 보이지 않는다.
/// [existingIds] 는 이미 있는 문서 id 모음, [makeId] 는 복사본용 새 id 를 만든다.
ImportResult importBackup({
  required String zipPath,
  required String docsRoot,
  required Set<String> existingIds,
  required DuplicatePolicy policy,
  required String Function() makeId,
  void Function(int index, int total)? onDoc,
}) {
  final result = ImportResult();
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final byDoc = <String, Map<String, ArchiveFile>>{};
    for (final f in archive) {
      if (!f.isFile || f.name == kBackupMarker) continue;
      final p = parseEntryName(f.name);
      if (p == null) continue;
      (byDoc[p.id] ??= {})[p.file] = f;
    }
    final ids = [for (final e in byDoc.entries) if (e.value.containsKey('doc.json')) e.key]..sort();
    final taken = {...existingIds};
    for (final (i, id) in ids.indexed) {
      onDoc?.call(i + 1, ids.length);
      final dup = taken.contains(id);
      if (dup && policy == DuplicatePolicy.skip) {
        result.skipped++;
        continue;
      }
      var target = id;
      if (dup) {
        target = makeId();
        while (!isValidDocId(target) ||
            taken.contains(target) ||
            Directory('$docsRoot/$target').existsSync()) {
          target = makeId();
        }
      }
      final tmp = Directory('$docsRoot/$target.importing');
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        tmp.createSync(recursive: true);
        final files = byDoc[id]!;
        for (final e in files.entries) {
          if (e.key == 'doc.json') continue;
          final out = OutputFileStream('${tmp.path}/${e.key}');
          try {
            e.value.writeContent(out);
          } finally {
            out.closeSync();
          }
        }
        var docJson = utf8.decode(files['doc.json']!.readBytes() ?? const []);
        // 깨진 doc.json, 또는 폴더 이름과 문서 id 가 다른 doc.json 이면 여기서 실패한다
        if ((jsonDecode(docJson) as Map<String, dynamic>)['id'] != id) throw BackupException('id 불일치');
        if (dup) docJson = rewriteDocJson(docJson, target);
        File('${tmp.path}/doc.json').writeAsStringSync(docJson, flush: true);
        tmp.renameSync('$docsRoot/$target');
        taken.add(target);
        if (dup) {
          result.copied++;
        } else {
          result.imported++;
        }
      } catch (_) {
        result.failed.add(id);
        try {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  } finally {
    input.closeSync();
  }
  return result;
}
