import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'ocr.dart';
import 'pdf_crypt.dart';
import 'scanner.dart';
import 'theme.dart';

enum SaveFormat { pdf, jpg, png, txt, docx, longImage }

enum SaveQuality { high, standard, small }

enum SaveTarget { device, gallery, share }

const _formatInfo = {
  SaveFormat.pdf: (Icons.picture_as_pdf_rounded, 'PDF', '문서 한 개로'),
  SaveFormat.jpg: (Icons.image_rounded, 'JPG', '페이지별 사진'),
  SaveFormat.png: (Icons.photo_rounded, 'PNG', '무손실 사진'),
  SaveFormat.txt: (Icons.notes_rounded, 'TXT', '인식된 글자'),
  SaveFormat.docx: (Icons.description_rounded, 'DOCX', '워드로 편집'),
  SaveFormat.longImage: (Icons.view_day_rounded, '긴 사진', '한 장으로 이어붙임'),
};

const _qualityInfo = {
  SaveQuality.high: ('고화질', null, 95),
  SaveQuality.standard: ('표준', 2200, 85),
  SaveQuality.small: ('작게', 1400, 72),
};

class SaveOptions {
  String name = '';
  /// 여러 형식을 한 번에 저장할 수 있다 (최소 1개)
  Set<SaveFormat> formats = {SaveFormat.pdf};
  SaveQuality quality = SaveQuality.high;
  bool a4 = false;
  bool searchable = true;
  bool onlySelected = true;

  /// 파일이 여러 개일 때 ZIP 하나로 묶기
  bool zip = false;

  /// 선택 기능 (기본 끔)
  bool pageNumbers = false;
  String? watermark; // 비어 있으면 없음
  String? password; // 비어 있으면 암호 없음
}

/// 지난번에 쓴 저장 설정을 기억해 다음에 기본값으로 쓴다 (암호·워터마크는 기억하지 않는다).
class _SavePrefs {
  static Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/save_prefs.json');

  static Future<void> load(SaveOptions o) async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final fm = {
        for (final n in (j['formats'] as List? ?? []).cast<String>())
          ...SaveFormat.values.where((v) => v.name == n),
      };
      if (fm.isNotEmpty) o.formats = fm;
      o.quality = SaveQuality.values.firstWhere((v) => v.name == j['quality'], orElse: () => o.quality);
      o.a4 = j['a4'] == true;
      o.searchable = j['searchable'] != false;
      o.pageNumbers = j['pageNumbers'] == true;
      o.zip = j['zip'] == true;
    } catch (_) {}
  }

  static Future<void> save(SaveOptions o) async {
    try {
      await (await _file()).writeAsString(jsonEncode({
        'formats': [for (final f in o.formats) f.name],
        'quality': o.quality.name,
        'a4': o.a4,
        'searchable': o.searchable,
        'pageNumbers': o.pageNumbers,
        'zip': o.zip,
      }));
    } catch (_) {}
  }
}

/// 저장 옵션 시트. 고른 옵션과 저장 방법을 돌려준다.
Future<(SaveOptions, SaveTarget)?> showSaveSheet(
    BuildContext context, int total, int selected, String docName) async {
  final o = SaveOptions()
    // 파일 이름에 쓸 수 없는 글자는 바꾼다
    ..name = docName.replaceAll(RegExp(r'[\/:*?"<>|]'), '-').replaceAll(' ', '_')
    ..onlySelected = selected > 0;
  await _SavePrefs.load(o);
  if (!context.mounted) return null;
  final nameCtl = TextEditingController(text: o.name);
  final pwCtl = TextEditingController(), wmCtl = TextEditingController(text: '사본');
  var usePw = false, useWm = false;

  return showModalBottomSheet<(SaveOptions, SaveTarget)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheet) => StatefulBuilder(builder: (sheet, set) {
      final hasPdf = o.formats.contains(SaveFormat.pdf);
      const imageFormats = {SaveFormat.jpg, SaveFormat.png, SaveFormat.longImage};
      final imagesOnly = o.formats.every(imageFormats.contains);
      final count = o.onlySelected ? selected : total;
      void go(SaveTarget t) {
        o.name = nameCtl.text.trim().isEmpty ? o.name : nameCtl.text.trim();
        o.password = usePw && pwCtl.text.isNotEmpty ? pwCtl.text : null;
        o.watermark = useWm && wmCtl.text.trim().isNotEmpty ? wmCtl.text.trim() : null;
        _SavePrefs.save(o);
        Navigator.pop(sheet, (o, t));
      }

      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheet).viewInsets.bottom),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 18),
                Text('저장하기', style: Theme.of(sheet).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('$count페이지', style: const TextStyle(color: AppColors.muted)),
                const SizedBox(height: 20),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                      labelText: '파일 이름', prefixIcon: Icon(Icons.edit_outlined)),
                ),
                const SizedBox(height: 22),
                const _Label('형식 (여러 개 선택 가능)'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final f in SaveFormat.values)
                    SizedBox(
                      width: (MediaQuery.of(sheet).size.width - 44 - 16) / 3,
                      child: _FormatCard(
                        info: _formatInfo[f]!,
                        selected: o.formats.contains(f),
                        // 마지막 하나는 끌 수 없다
                        onTap: () => set(() {
                          if (!o.formats.remove(f) || o.formats.isEmpty) o.formats.add(f);
                        }),
                      ),
                    ),
                ]),
                if (o.formats.any((f) => f != SaveFormat.txt && f != SaveFormat.docx)) ...[
                  const SizedBox(height: 22),
                  const _Label('화질'),
                  SegmentedButton<SaveQuality>(
                    showSelectedIcon: false,
                    segments: [
                      for (final q in SaveQuality.values)
                        ButtonSegment(value: q, label: Text(_qualityInfo[q]!.$1)),
                    ],
                    selected: {o.quality},
                    onSelectionChanged: (v) => set(() => o.quality = v.first),
                  ),
                ],
                if (hasPdf) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('글자 검색 가능 (OCR)'),
                    subtitle: const Text('PDF에서 검색·복사할 수 있게',
                        style: TextStyle(color: AppColors.muted)),
                    value: o.searchable,
                    onChanged: (v) => set(() => o.searchable = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('A4 크기로 맞춤'),
                    subtitle: const Text('끄면 페이지 비율 그대로',
                        style: TextStyle(color: AppColors.muted)),
                    value: o.a4,
                    onChanged: (v) => set(() => o.a4 = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('페이지 번호'),
                    subtitle: const Text('아래 가운데에 1 / N', style: TextStyle(color: AppColors.muted)),
                    value: o.pageNumbers,
                    onChanged: (v) => set(() => o.pageNumbers = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('워터마크'),
                    subtitle: const Text('페이지 가운데 흐린 글자', style: TextStyle(color: AppColors.muted)),
                    value: useWm,
                    onChanged: (v) => set(() => useWm = v),
                  ),
                  if (useWm)
                    TextField(
                      controller: wmCtl,
                      decoration: const InputDecoration(
                          labelText: '워터마크 글자', prefixIcon: Icon(Icons.water_drop_outlined)),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('암호 걸기'),
                    subtitle: const Text('열 때 암호를 물어요 (영문·숫자)', style: TextStyle(color: AppColors.muted)),
                    value: usePw,
                    onChanged: (v) => set(() => usePw = v),
                  ),
                  if (usePw)
                    TextField(
                      controller: pwCtl,
                      obscureText: true,
                      keyboardType: TextInputType.visiblePassword,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\x21-\x7E]'))],
                      decoration: const InputDecoration(
                          labelText: '암호 (영문·숫자·기호)', prefixIcon: Icon(Icons.lock_outline_rounded)),
                    ),
                ],
                if (o.formats.length > 1 ||
                    (count > 1 && (o.formats.contains(SaveFormat.jpg) || o.formats.contains(SaveFormat.png))))
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('ZIP 하나로 묶기'),
                    subtitle: const Text('파일이 여러 개일 때 한 파일로', style: TextStyle(color: AppColors.muted)),
                    value: o.zip,
                    onChanged: (v) => set(() => o.zip = v),
                  ),
                if (selected > 0 && selected < total)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('선택한 $selected페이지만'),
                    value: o.onlySelected,
                    onChanged: (v) => set(() => o.onlySelected = v),
                  ),
                const SizedBox(height: 22),
                if (o.formats.length > 1 && !imagesOnly && !o.zip)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text('사진은 갤러리에, PDF·TXT는 저장 위치를 물어보고 저장해요',
                        style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('공유'),
                      onPressed: () => go(SaveTarget.share),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      icon: Icon(imagesOnly ? Icons.photo_library_rounded : Icons.download_rounded),
                      label: Text(o.formats.length > 1
                          ? '${o.formats.length}개 형식 저장'
                          : imagesOnly
                              ? '갤러리에 저장'
                              : '기기에 저장'),
                      onPressed: () => go(imagesOnly ? SaveTarget.gallery : SaveTarget.device),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      );
    }),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: .5)),
      );
}

class _FormatCard extends StatelessWidget {
  const _FormatCard({required this.info, required this.selected, required this.onTap});

  final (IconData, String, String) info;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent.withValues(alpha: .14) : AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? AppColors.accent : Colors.white10, width: 1.5),
        ),
        child: Column(children: [
          Icon(info.$1, color: selected ? AppColors.accent : Colors.white70, size: 28),
          const SizedBox(height: 6),
          Text(info.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(info.$3, style: const TextStyle(color: AppColors.muted, fontSize: 10.5)),
        ]),
      ),
    );
  }
}

// ───────────────────────── 실제 저장 ─────────────────────────

/// 옵션대로 파일을 만들어 저장·공유한다. 사용자에게 보여줄 결과 문장을 돌려준다 (취소면 null).
/// 형식을 여러 개 고르면 한 번에 모두 만든다.
Future<String?> runSave(List<ScanPage> pages, SaveOptions o, SaveTarget target) async {
  final (_, maxSide, quality) = _qualityInfo[o.quality]!;
  final outs = <(String, Uint8List, String)>[]; // 이름, 내용, mime

  for (final f in SaveFormat.values) {
    if (!o.formats.contains(f)) continue;
    switch (f) {
      case SaveFormat.pdf:
        outs.add(('${o.name}.pdf', await _buildPdf(pages, o, maxSide, quality), 'application/pdf'));

      case SaveFormat.txt:
        final text = [
          for (var i = 0; i < pages.length; i++) '── ${i + 1}페이지 ──\n${pages[i].ocr?.text ?? ''}',
        ].join('\n\n');
        // BOM을 붙여야 윈도우 메모장에서도 한글이 깨지지 않는다
        outs.add(('${o.name}.txt', Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]), 'text/plain'));

      case SaveFormat.docx:
        outs.add((
          '${o.name}.docx',
          _buildDocx(pages),
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
        ));

      case SaveFormat.longImage:
        final long = await compute(stitchLong, ([for (final p in pages) p.jpg], quality));
        outs.add(('${o.name}_long.jpg', long, 'image/jpeg'));

      case SaveFormat.jpg:
      case SaveFormat.png:
        final ext = f.name;
        for (var i = 0; i < pages.length; i++) {
          final bytes = maxSide == null && ext == 'jpg'
              ? pages[i].jpg
              : await compute(transcode, (pages[i].jpg, ext, maxSide, quality));
          final suffix = pages.length == 1 ? '' : '_${(i + 1).toString().padLeft(3, '0')}';
          outs.add(('${o.name}$suffix.$ext', bytes, ext == 'jpg' ? 'image/jpeg' : 'image/png'));
        }
    }
  }

  if (o.zip && outs.length > 1) {
    final zip = Archive();
    for (final (name, bytes, _) in outs) {
      zip.addFile(ArchiveFile.bytes(name, bytes));
    }
    outs
      ..clear()
      ..add(('${o.name}.zip', Uint8List.fromList(ZipEncoder().encode(zip)), 'application/zip'));
  }

  if (target == SaveTarget.share) {
    final dir = await getTemporaryDirectory();
    final xs = <XFile>[];
    for (final (name, bytes, mime) in outs) {
      xs.add(XFile((await File('${dir.path}/$name').writeAsBytes(bytes)).path, mimeType: mime));
    }
    await SharePlus.instance.share(ShareParams(files: xs));
    return null;
  }

  // 기기 저장: 사진은 갤러리로, PDF·TXT는 저장 위치를 고르는 시스템 저장 창으로
  final bothImages = o.formats.contains(SaveFormat.jpg) && o.formats.contains(SaveFormat.png);
  var photos = 0;
  final docs = <String>[];
  for (final (name, bytes, mime) in outs) {
    if (mime.startsWith('image/')) {
      if (photos == 0 && !await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      // JPG·PNG를 같이 저장하면 이름이 겹치지 않게 확장자를 이름에 남긴다
      final gname = bothImages ? name.replaceAll('.', '_') : name.split('.').first;
      await Gal.putImageBytes(bytes, album: 'BookScan', name: gname);
      photos++;
    } else {
      final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime);
      if (uri != null) docs.add(name);
    }
  }
  final parts = [
    if (docs.isNotEmpty) docs.join(', '),
    if (photos > 0) '사진 $photos장(갤러리 BookScan 앨범)',
  ];
  return parts.isEmpty ? null : '${parts.join(' + ')} 저장 완료';
}

String _xml(String t) =>
    t.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// OCR 글자를 페이지별로 담은 워드 문서(.docx). 페이지 사이에 쪽 나누기가 들어간다.
Uint8List _buildDocx(List<ScanPage> pages) {
  final body = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    if (i > 0) body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
    for (final line in (pages[i].ocr?.text ?? '').split('\n')) {
      body.write('<w:p><w:r><w:t xml:space="preserve">${_xml(line)}</w:t></w:r></w:p>');
    }
  }
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

/// 검색 가능한 PDF: 페이지 사진 위에 OCR 글자를 보이지 않게 겹쳐 넣는다.
Future<Uint8List> _buildPdf(List<ScanPage> pages, SaveOptions o, int? maxSide, int quality) async {
  final font = pw.Font.ttf(await rootBundle.load('assets/fonts/NanumGothic-Regular.ttf'));
  // 암호를 걸 때는 객체 스트림이 없는 PDF 1.4로 (호환성)
  final doc = pw.Document(
      title: o.name, creator: '북스캔', version: o.password != null ? PdfVersion.pdf_1_4 : PdfVersion.pdf_1_5);
  if (o.password != null) {
    doc.document.encryption = PdfPasswordEncryption(doc.document, o.password!);
  }
  var pageNo = 0;
  for (final p in pages) {
    final no = ++pageNo; // 페이지는 나중에 그려지므로 번호를 미리 붙잡아 둔다
    final bytes =
        maxSide == null ? p.jpg : await compute(transcode, (p.jpg, 'jpg', maxSide, quality));
    final img = pw.MemoryImage(bytes);
    // OCR 좌표는 원본 픽셀 기준
    final src = pw.MemoryImage(p.jpg);
    final w = PdfPageFormat.a4.width;
    final h = o.a4 ? PdfPageFormat.a4.height : w * src.height! / src.width!;
    // A4면 비율 유지해서 가운데 배치
    final s = o.a4 ? (w / src.width!).clamp(0.0, h / src.height!) : w / src.width!;
    final dx = (w - src.width! * s) / 2, dy = (h - src.height! * s) / 2;

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(w, h),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Stack(children: [
        pw.Positioned(
            left: dx,
            top: dy,
            child: pw.Image(img, width: src.width! * s, height: src.height! * s, fit: pw.BoxFit.fill)),
        if (o.searchable)
          for (final l in p.ocr?.lines ?? <OcrLine>[])
            if (l.box.width > 0 && l.box.height > 0)
              pw.Positioned(
                left: dx + l.box.left * s,
                top: dy + l.box.top * s,
                child: pw.SizedBox(
                  width: l.box.width * s,
                  height: l.box.height * s,
                  child: pw.FittedBox(
                    fit: pw.BoxFit.fill,
                    child: pw.Text(l.text,
                        style: pw.TextStyle(
                            font: font, fontSize: 10, renderingMode: PdfTextRenderingMode.invisible)),
                  ),
                ),
              ),
        // 워터마크: 가운데 비스듬히 흐린 글자
        if (o.watermark != null)
          pw.Positioned.fill(
            child: pw.Center(
              child: pw.Transform.rotate(
                angle: 0.6,
                child: pw.Opacity(
                  opacity: 0.18,
                  child: pw.Text(o.watermark!,
                      style: pw.TextStyle(font: font, fontSize: w * 0.12, color: PdfColors.grey800)),
                ),
              ),
            ),
          ),
        // 페이지 번호: 아래 가운데
        if (o.pageNumbers)
          pw.Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: pw.Center(
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: pw.BoxDecoration(
                    color: PdfColors.white, borderRadius: pw.BorderRadius.circular(6)),
                child: pw.Text('$no / ${pages.length}',
                    style: pw.TextStyle(font: font, fontSize: 10, color: PdfColors.grey700)),
              ),
            ),
          ),
      ]),
    ));
  }
  return doc.save();
}

/// 공유하기: 형식을 (여러 개) 고르고 누르면 안드로이드 공유 창(카카오톡·메일 등)이 열린다.
Future<void> shareDocument(BuildContext context, List<ScanPage> pages, String docName) async {
  final picked = <SaveFormat>{SaveFormat.pdf};
  final formats = await showModalBottomSheet<Set<SaveFormat>>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (s) => StatefulBuilder(
      builder: (s, set) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('공유하기', style: Theme.of(s).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('${pages.length}페이지 · 여러 형식을 함께 보낼 수 있어요',
                style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 16),
            for (final (f, icon, title, sub) in [
              (SaveFormat.pdf, Icons.picture_as_pdf_rounded, 'PDF 한 개로', '글자 검색 가능'),
              (SaveFormat.jpg, Icons.image_rounded, '사진(JPG)으로', '페이지마다 한 장'),
              (SaveFormat.png, Icons.photo_rounded, '사진(PNG)으로', '무손실, 용량 큼'),
              (SaveFormat.txt, Icons.notes_rounded, '글자(TXT)로', '인식된 글자만'),
              (SaveFormat.docx, Icons.description_rounded, '워드(DOCX)로', '인식된 글자를 편집'),
              (SaveFormat.longImage, Icons.view_day_rounded, '긴 사진 한 장으로', '페이지를 위아래로 이어붙임'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(16),
                  child: CheckboxListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    secondary: Icon(icon, color: AppColors.accent),
                    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(sub, style: const TextStyle(color: AppColors.muted)),
                    value: picked.contains(f),
                    onChanged: (v) => set(() {
                      v == true ? picked.add(f) : picked.remove(f);
                    }),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.ios_share_rounded),
                label: Text('${picked.length}개 형식 공유'),
                onPressed: picked.isEmpty ? null : () => Navigator.pop(s, picked),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
  if (formats == null || formats.isEmpty) return;
  final o = SaveOptions()
    ..name = docName.replaceAll(RegExp(r'[\/:*?"<>|]'), '-').replaceAll(' ', '_')
    ..formats = formats
    ..quality = SaveQuality.standard;
  await runSave(pages, o, SaveTarget.share);
}
