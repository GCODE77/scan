// 태그 다듬기와 문서 검색의 순수 부분. Flutter·파일·플랫폼에 기대지 않아서 PC에서 `dart test`로 시험한다.

/// 태그 한 개의 최대 글자 수
const int kTagMaxLen = 20;

/// 입력한 태그 글자를 다듬는다: 앞의 '#' 제거, 공백 정리, 너무 길면 자름. 비면 null.
String? cleanTag(String raw) {
  var t = raw.trim();
  while (t.startsWith('#')) {
    t = t.substring(1).trimLeft();
  }
  t = t.replaceAll(RegExp(r'\s+'), ' ');
  if (t.isEmpty) return null;
  if (t.length > kTagMaxLen) t = t.substring(0, kTagMaxLen).trimRight();
  return t;
}

/// 쉼표·줄바꿈으로 나눠 적은 태그 입력을 태그 목록으로 (띄어쓰기는 태그 안에 둔다).
List<String> parseTagInput(String input) => normalizeTags(input.split(RegExp(r'[,\n，]')));

/// 다듬고, 대소문자 구분 없이 같은 것은 먼저 나온 것만 남긴다. 순서는 입력 순서.
List<String> normalizeTags(Iterable<String> tags) {
  final seen = <String>{};
  final out = <String>[];
  for (final raw in tags) {
    final t = cleanTag(raw);
    if (t == null) continue;
    if (seen.add(t.toLowerCase())) out.add(t);
  }
  return out;
}

/// [current] 에서 [remove] 를 빼고 [add] 를 더한다 (대소문자 구분 없이 비교).
List<String> applyTagChanges(List<String> current,
    {Iterable<String> add = const [], Iterable<String> remove = const []}) {
  final rm = {for (final t in normalizeTags(remove)) t.toLowerCase()};
  return normalizeTags([
    for (final t in current)
      if (!rm.contains(t.toLowerCase())) t,
    ...add,
  ]);
}

/// 문서 목록에 쓰인 모든 태그 (대소문자 구분 없이 하나로, 가나다순).
List<String> allTags(Iterable<List<String>> tagLists) {
  final byLower = <String, String>{};
  for (final l in tagLists) {
    for (final t in l) {
      byLower.putIfAbsent(t.toLowerCase(), () => t);
    }
  }
  final out = byLower.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

bool hasTag(List<String> tags, String tag) {
  final l = tag.toLowerCase();
  return tags.any((t) => t.toLowerCase() == l);
}

/// 검색 대상 문서 한 개의 글자들.
class SearchDoc {
  SearchDoc({
    required this.name,
    this.tags = const [],
    this.memo = '',
    this.pageTexts = const [],
    this.pageMemos = const [],
  });

  final String name;
  final List<String> tags;
  final String memo;

  /// 페이지별 OCR 글자 (null 이면 글자 인식 안 된 페이지)
  final List<String?> pageTexts;
  final List<String> pageMemos;

  int get ocrMissing => pageTexts.where((t) => t == null).length;
}

/// 맞은 곳. [where] 는 '이름' '태그' '문서 메모' '페이지 메모' '본문', [page] 는 1부터(문서 단위면 null), [snippet] 은 주변 글자.
class SearchHit {
  SearchHit(this.where, this.page, this.snippet);
  final String where;
  final int? page;
  final String snippet;

  /// 목록에 한 줄로 보일 글 (이름에서 맞았으면 빈 글자)
  String get line {
    if (where == '이름') return '';
    return page == null ? '$where: $snippet' : '$where p.$page: $snippet';
  }

  @override
  String toString() => line;
}

List<String> searchTerms(String query) =>
    [for (final t in query.trim().toLowerCase().split(RegExp(r'\s+'))) if (t.isNotEmpty) t];

/// [d] 가 [terms] 를 모두 포함하는지(이름·태그·메모·페이지 메모·본문 어디든) 보고, 맞으면 맞은 곳 하나를 돌려준다.
/// 맞지 않으면 null. [terms] 가 비어 있으면 모두 맞은 것으로 보고 '이름' 결과를 돌려준다.
SearchHit? searchDoc(SearchDoc d, List<String> terms) {
  if (terms.isEmpty) return SearchHit('이름', null, '');
  final name = d.name.toLowerCase();
  final tags = d.tags.map((t) => t.toLowerCase()).toList();
  final memo = d.memo.toLowerCase();
  final pmemo = [for (final m in d.pageMemos) m.toLowerCase()];
  final body = [for (final t in d.pageTexts) t?.toLowerCase() ?? ''];

  bool termIn(String t) =>
      name.contains(t) ||
      tags.any((x) => x.contains(t)) ||
      memo.contains(t) ||
      pmemo.any((x) => x.contains(t)) ||
      body.any((x) => x.contains(t));
  if (!terms.every(termIn)) return null;

  // 맞은 곳 하나 고르기: 이름 > 태그 > 문서 메모 > 페이지 메모 > 본문 (용어 하나라도 들어 있는 첫 곳)
  if (terms.any(name.contains)) return SearchHit('이름', null, '');
  for (var i = 0; i < tags.length; i++) {
    if (terms.any(tags[i].contains)) return SearchHit('태그', null, d.tags[i]);
  }
  if (terms.any(memo.contains)) return SearchHit('문서 메모', null, snippetAround(d.memo, terms));
  for (var i = 0; i < pmemo.length; i++) {
    if (terms.any(pmemo[i].contains)) return SearchHit('페이지 메모', i + 1, snippetAround(d.pageMemos[i], terms));
  }
  for (var i = 0; i < body.length; i++) {
    if (terms.any(body[i].contains)) return SearchHit('본문', i + 1, snippetAround(d.pageTexts[i]!, terms));
  }
  return SearchHit('이름', null, '');
}

/// [text] 에서 첫 번째로 맞은 용어 주변 글자를 한 줄로 (줄바꿈은 공백으로, 잘리면 …).
String snippetAround(String text, List<String> terms, {int before = 10, int after = 24}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ');
  final lower = flat.toLowerCase();
  var at = -1;
  var len = 0;
  for (final t in terms) {
    final i = lower.indexOf(t);
    if (i >= 0 && (at < 0 || i < at)) {
      at = i;
      len = t.length;
    }
  }
  if (at < 0 || lower.length != flat.length) {
    // 못 찾았거나 소문자로 바꾸며 길이가 달라지면 앞부분만
    return flat.length <= before + after ? flat : '${flat.substring(0, before + after)}…';
  }
  final s = at - before < 0 ? 0 : at - before;
  final e = at + len + after > flat.length ? flat.length : at + len + after;
  return '${s > 0 ? '…' : ''}${flat.substring(s, e)}${e < flat.length ? '…' : ''}';
}
