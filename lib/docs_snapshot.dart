// 업데이트 전 문서 사본 만들기·되돌리기의 순수 부분. dart:io 만 쓰므로 PC 에서 `dart test` 로 시험한다.
//
// 폴더 배치 (모두 [base] 아래, base 는 앱 문서 폴더)
//   docs/                     지금 문서
//   docs_before_v030/         업데이트 전 사본 (만들기가 끝난 뒤에만 이 이름으로 나타남)
//   docs_before_v030.tmp/     사본을 만드는 중인 폴더 (중간에 꺼지면 남을 수 있음)
//   docs_before_v030.done     '사본 단계를 한 번 처리했다'는 표시 파일
//   docs_replaced_v030/       되돌리는 도중의 임시 이름
import 'dart:io';

const String kSnapshotDir = 'docs_before_v030';
const String kSnapshotTmp = 'docs_before_v030.tmp';
const String kSnapshotMarker = 'docs_before_v030.done';
const String kReplacedDir = 'docs_replaced_v030';

/// 폴더 안 모든 파일 크기 합 (없으면 0).
int dirSize(Directory d) {
  if (!d.existsSync()) return 0;
  var n = 0;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File) n += e.lengthSync();
  }
  return n;
}

/// 폴더 안에 doc.json 이 있는 문서가 하나라도 있는지.
bool hasAnyDoc(Directory docs) {
  if (!docs.existsSync()) return false;
  for (final e in docs.listSync(followLinks: false)) {
    if (e is Directory && File('${e.path}/doc.json').existsSync()) return true;
  }
  return false;
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final e in from.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      _copyTree(e, Directory('${to.path}/$name'));
    } else if (e is File) {
      if (name.endsWith('.tmp')) continue; // 저장 도중에 남은 임시 파일은 사본에 넣지 않는다
      e.copySync('${to.path}/$name');
    }
  }
}

/// [docs] 를 [base]/docs_before_v030 으로 복사한다. 끝나면 true.
/// 임시 이름으로 복사한 뒤 이름을 바꿔 붙이므로, 중간에 실패하면 완성된 사본은 생기지 않는다.
/// 이미 사본이 있으면 건드리지 않고 true.
bool makeSnapshot(String base, {Directory? docs}) {
  final src = docs ?? Directory('$base/docs');
  final snap = Directory('$base/$kSnapshotDir');
  if (snap.existsSync()) return true;
  final tmp = Directory('$base/$kSnapshotTmp');
  try {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    _copyTree(src, tmp);
    tmp.renameSync(snap.path);
    return true;
  } catch (_) {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {}
    return false;
  }
}

bool snapshotExists(String base) => Directory('$base/$kSnapshotDir').existsSync();

/// 표시 파일 기록.
void writeMarker(String base, String note) => File('$base/$kSnapshotMarker').writeAsStringSync(note);

bool markerExists(String base) => File('$base/$kSnapshotMarker').existsSync();

/// 사본으로 문서 폴더를 바꿔 놓는다. 새로 복사하지 않고 이름만 바꾸므로 공간이 더 들지 않는다.
/// 지금 문서 폴더는 잠깐 docs_replaced_v030 으로 옮겼다가 지운다.
/// 사본이 없으면 false. 이름 바꾸기가 실패하면 원래대로 돌려놓고 false.
bool restoreSnapshot(String base) {
  final snap = Directory('$base/$kSnapshotDir');
  if (!snap.existsSync()) return false;
  final docs = Directory('$base/docs');
  final replaced = Directory('$base/$kReplacedDir');
  try {
    if (replaced.existsSync()) replaced.deleteSync(recursive: true);
    final hadDocs = docs.existsSync();
    if (hadDocs) docs.renameSync(replaced.path);
    try {
      snap.renameSync(docs.path);
    } catch (_) {
      if (hadDocs) replaced.renameSync(docs.path); // 원래대로
      return false;
    }
    try {
      if (replaced.existsSync()) replaced.deleteSync(recursive: true);
    } catch (_) {} // 못 지워도 되돌리기는 성공
    return true;
  } catch (_) {
    return false;
  }
}
