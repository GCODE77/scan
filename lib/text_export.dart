// TXT·DOCX 내보내기의 순수 부분. OCR 글자와 메모를 페이지 순서대로 한 파일에 담는다.
// Flutter·ScanPage 에 기대지 않고 글자만 받는다 (PC에서 `dart test`로 시험).
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 내보낼 페이지 한 장의 글자.
class ExportPage {
  const ExportPage(this.text, [this.memo = '']);

  /// OCR 글자 (글자 인식 안 됐으면 빈 글자)
  final String text;
  final String memo;
}

/// 메모를 넣을 수 있는지 (문서 메모나 페이지 메모가 하나라도 있으면).
bool hasAnyMemo(String docMemo, List<ExportPage> pages) =>
    docMemo.trim().isNotEmpty || pages.any((p) => p.memo.trim().isNotEmpty);

const String _docMemoTitle = '── 문서 메모 ──';

/// TXT 글자. 메모를 빼면 이전 버전과 똑같다.
String buildTxtText(List<ExportPage> pages, {String docMemo = '', bool includeMemo = false}) {
  final parts = <String>[];
  if (includeMemo && docMemo.trim().isNotEmpty) parts.add('$_docMemoTitle\n$docMemo');
  for (var i = 0; i < pages.length; i++) {
    final b = StringBuffer('── ${i + 1}페이지 ──\n${pages[i].text}');
    if (includeMemo && pages[i].memo.trim().isNotEmpty) b.write('\n[메모] ${pages[i].memo}');
    parts.add(b.toString());
  }
  return parts.join('\n\n');
}

/// TXT 파일 바이트. BOM을 붙여야 윈도우 메모장에서도 한글이 깨지지 않는다.
Uint8List buildTxtBytes(List<ExportPage> pages, {String docMemo = '', bool includeMemo = false}) =>
    Uint8List.fromList(
        [0xEF, 0xBB, 0xBF, ...utf8.encode(buildTxtText(pages, docMemo: docMemo, includeMemo: includeMemo))]);

/// XML 글자 칸에 넣을 수 있게: & < > 를 바꾸고, XML 1.0 에서 쓸 수 없는 제어 문자는 뺀다.
String xmlEscape(String t) {
  final b = StringBuffer();
  for (final r in t.runes) {
    final ok = r == 0x9 ||
        r == 0xA ||
        r == 0xD ||
        (r >= 0x20 && r <= 0xD7FF) ||
        (r >= 0xE000 && r <= 0xFFFD) ||
        (r >= 0x10000 && r <= 0x10FFFF);
    if (!ok) continue;
    switch (r) {
      case 0x26:
        b.write('&amp;');
      case 0x3C:
        b.write('&lt;');
      case 0x3E:
        b.write('&gt;');
      default:
        b.writeCharCode(r);
    }
  }
  return b.toString();
}

String _para(String line, {bool bold = false, String? color}) {
  final rpr = bold || color != null
      ? '<w:rPr>${bold ? '<w:b/>' : ''}${color != null ? '<w:color w:val="$color"/>' : ''}</w:rPr>'
      : '';
  return '<w:p><w:r>$rpr<w:t xml:space="preserve">${xmlEscape(line)}</w:t></w:r></w:p>';
}

const String _pageBreak = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>';

/// document.xml 의 body 안쪽. 메모를 빼면 이전 버전과 똑같다.
String buildDocxBody(List<ExportPage> pages, {String docMemo = '', bool includeMemo = false}) {
  final body = StringBuffer();
  if (includeMemo && docMemo.trim().isNotEmpty) {
    body.write(_para('문서 메모', bold: true));
    for (final l in docMemo.split('\n')) {
      body.write(_para(l));
    }
    body.write(_pageBreak);
  }
  for (var i = 0; i < pages.length; i++) {
    if (i > 0) body.write(_pageBreak);
    for (final line in pages[i].text.split('\n')) {
      body.write(_para(line));
    }
    if (includeMemo && pages[i].memo.trim().isNotEmpty) {
      body.write(_para('[메모]', bold: true, color: '808080'));
      for (final l in pages[i].memo.split('\n')) {
        body.write(_para(l, color: '808080'));
      }
    }
  }
  return body.toString();
}

/// 편집 가능한 워드 문서(.docx) 바이트. 페이지 사이에 쪽 나누기가 들어간다.
Uint8List buildDocxBytes(List<ExportPage> pages, {String docMemo = '', bool includeMemo = false}) {
  final body = buildDocxBody(pages, docMemo: docMemo, includeMemo: includeMemo);
  const ns = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  Uint8List u(String s) => Uint8List.fromList(utf8.encode(s));
  final z = Archive()
    ..addFile(ArchiveFile.bytes(
        '[Content_Types].xml',
        u('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '</Types>')))
    ..addFile(ArchiveFile.bytes(
        '_rels/.rels',
        u('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '</Relationships>')))
    ..addFile(ArchiveFile.bytes(
        'word/document.xml',
        u('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:document xmlns:w="$ns"><w:body>$body<w:sectPr/></w:body></w:document>')));
  return Uint8List.fromList(ZipEncoder().encode(z));
}
