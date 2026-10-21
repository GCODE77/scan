import 'dart:convert';
import 'dart:io';

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
import 'scanner.dart';
import 'theme.dart';

enum SaveFormat { pdf, jpg, png, txt }

enum SaveQuality { high, standard, small }

enum SaveTarget { device, gallery, share }

const _formatInfo = {
  SaveFormat.pdf: (Icons.picture_as_pdf_rounded, 'PDF', '문서 한 개로'),
  SaveFormat.jpg: (Icons.image_rounded, 'JPG', '페이지별 사진'),
  SaveFormat.png: (Icons.photo_rounded, 'PNG', '무손실 사진'),
  SaveFormat.txt: (Icons.notes_rounded, 'TXT', '인식된 글자'),
};

const _qualityInfo = {
  SaveQuality.high: ('고화질', null, 95),
  SaveQuality.standard: ('표준', 2200, 85),
  SaveQuality.small: ('작게', 1400, 72),
};

class SaveOptions {
  String name = '';
  SaveFormat format = SaveFormat.pdf;
  SaveQuality quality = SaveQuality.high;
  bool a4 = false;
  bool searchable = true;
  bool onlySelected = true;
}

/// 저장 옵션 시트. 고른 옵션과 저장 방법을 돌려준다.
Future<(SaveOptions, SaveTarget)?> showSaveSheet(
    BuildContext context, int total, int selected, String docName) {
  final o = SaveOptions()
    // 파일 이름에 쓸 수 없는 글자는 바꾼다
    ..name = docName.replaceAll(RegExp(r'[\/:*?"<>|]'), '-').replaceAll(' ', '_')
    ..onlySelected = selected > 0;
  final nameCtl = TextEditingController(text: o.name);

  return showModalBottomSheet<(SaveOptions, SaveTarget)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheet) => StatefulBuilder(builder: (sheet, set) {
      final isImage = o.format == SaveFormat.jpg || o.format == SaveFormat.png;
      final count = o.onlySelected ? selected : total;
      void go(SaveTarget t) {
        o.name = nameCtl.text.trim().isEmpty ? o.name : nameCtl.text.trim();
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
                const _Label('형식'),
                Row(children: [
                  for (final f in SaveFormat.values)
                    Expanded(
                      child: _FormatCard(
                        info: _formatInfo[f]!,
                        selected: o.format == f,
                        onTap: () => set(() => o.format = f),
                      ),
                    ),
                ]),
                if (o.format != SaveFormat.txt) ...[
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
                if (o.format == SaveFormat.pdf) ...[
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
                ],
                if (selected > 0 && selected < total)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('선택한 $selected페이지만'),
                    value: o.onlySelected,
                    onChanged: (v) => set(() => o.onlySelected = v),
                  ),
                const SizedBox(height: 22),
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
                      icon: Icon(isImage ? Icons.photo_library_rounded : Icons.download_rounded),
                      label: Text(isImage ? '갤러리에 저장' : '기기에 저장'),
                      onPressed: () => go(isImage ? SaveTarget.gallery : SaveTarget.device),
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
        margin: const EdgeInsets.symmetric(horizontal: 4),
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
Future<String?> runSave(List<ScanPage> pages, SaveOptions o, SaveTarget target) async {
  final (_, maxSide, quality) = _qualityInfo[o.quality]!;

  switch (o.format) {
    case SaveFormat.pdf:
      final bytes = await _buildPdf(pages, o, maxSide, quality);
      return _deliverOne('${o.name}.pdf', bytes, 'application/pdf', target);

    case SaveFormat.txt:
      final text = [
        for (var i = 0; i < pages.length; i++) '── ${i + 1}페이지 ──\n${pages[i].ocr?.text ?? ''}',
      ].join('\n\n');
      // BOM을 붙여야 윈도우 메모장에서도 한글이 깨지지 않는다
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
      return _deliverOne('${o.name}.txt', bytes, 'text/plain', target);

    case SaveFormat.jpg:
    case SaveFormat.png:
      final ext = o.format.name;
      final files = <(String, Uint8List)>[];
      for (var i = 0; i < pages.length; i++) {
        final bytes = maxSide == null && ext == 'jpg'
            ? pages[i].jpg
            : await compute(transcode, (pages[i].jpg, ext, maxSide, quality));
        final suffix = pages.length == 1 ? '' : '_${(i + 1).toString().padLeft(3, '0')}';
        files.add(('${o.name}$suffix.$ext', bytes));
      }
      if (target == SaveTarget.share) {
        final dir = await getTemporaryDirectory();
        final xs = <XFile>[];
        for (final (name, bytes) in files) {
          xs.add(XFile((await File('${dir.path}/$name').writeAsBytes(bytes)).path));
        }
        await SharePlus.instance.share(ShareParams(files: xs));
        return null;
      }
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      for (final (name, bytes) in files) {
        await Gal.putImageBytes(bytes, album: 'BookScan', name: name.split('.').first);
      }
      return '사진 ${files.length}장을 갤러리 BookScan 앨범에 저장했습니다';
  }
}

Future<String?> _deliverOne(String name, Uint8List bytes, String mime, SaveTarget target) async {
  if (target == SaveTarget.share) {
    final dir = await getTemporaryDirectory();
    final f = await File('${dir.path}/$name').writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: mime)]));
    return null;
  }
  // 저장 위치와 이름을 사용자가 고르는 시스템 저장 창
  final uri = await FilePicker.saveFile(fileName: name, bytes: bytes, mimeType: mime);
  return uri == null ? null : '$name 저장 완료';
}

/// 검색 가능한 PDF: 페이지 사진 위에 OCR 글자를 보이지 않게 겹쳐 넣는다.
Future<Uint8List> _buildPdf(List<ScanPage> pages, SaveOptions o, int? maxSide, int quality) async {
  final font = pw.Font.ttf(await rootBundle.load('assets/fonts/NanumGothic-Regular.ttf'));
  final doc = pw.Document(title: o.name, creator: '북스캔');
  for (final p in pages) {
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
      ]),
    ));
  }
  return doc.save();
}
