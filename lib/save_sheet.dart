import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
    BuildContext context, List<ScanPage> pages, Set<ScanPage> selectedPages, String docName) async {
  final total = pages.length, selected = selectedPages.length;
  final o = SaveOptions()
    // 파일 이름에 쓸 수 없는 글자는 바꾼다
    ..name = docName.replaceAll(RegExp(r'[\/:*?"<>|]'), '-').replaceAll(' ', '_')
    ..onlySelected = selected > 0;
  await _SavePrefs.load(o);
  if (!context.mounted) return null;
  final nameCtl = TextEditingController(text: o.name);
  final pwCtl = TextEditingController(), wmCtl = TextEditingController(text: '사본');
  var usePw = false, useWm = false;

  // 예상 용량: 가운데쯤 크기의 페이지 한 장을 화질 단계마다 실제로 인코딩해 보고 전체로 늘린다 (시트는 바로 열린다)
  final probe = ValueNotifier<Map<String, int>?>(null);
  if (pages.isNotEmpty) {
    final bySize = [...pages]..sort((a, b) => a.jpg.length.compareTo(b.jpg.length));
    compute(probeSizes, (
      bySize[bySize.length ~/ 2].jpg,
      [for (final q in SaveQuality.values) (_qualityInfo[q]!.$2, _qualityInfo[q]!.$3)],
    )).then((m) => probe.value = m, onError: (_) {});
  }

  return showModalBottomSheet<(SaveOptions, SaveTarget)>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheet) => ValueListenableBuilder<Map<String, int>?>(
        valueListenable: probe,
        builder: (_, pr, _) => StatefulBuilder(builder: (sheet, set) {
      final hasPdf = o.formats.contains(SaveFormat.pdf);
      const imageFormats = {SaveFormat.jpg, SaveFormat.png, SaveFormat.longImage};
      final count = o.onlySelected ? selected : total;
      // ZIP 스위치가 보이는 경우: 파일이 여러 개가 될 때
      final zipVisible = o.formats.length > 1 ||
          (count > 1 && (o.formats.contains(SaveFormat.jpg) || o.formats.contains(SaveFormat.png)));
      // ZIP으로 묶으면 사진이 아니라 파일 하나라서 갤러리가 아니라 저장 창으로 간다
      final imagesOnly = !(o.zip && zipVisible) && o.formats.every(imageFormats.contains);

      // ── 예상 용량 ──
      final targets = o.onlySelected && selected > 0 ? [for (final p in pages) if (selectedPages.contains(p)) p] : pages;
      final est = _SizeEstimate(pr, targets, o);
      final ocrPending = targets.any((p) => p.ocr == null);
      String sizeLabel(SaveFormat f) {
        final b = est.bytes(f, o.quality);
        if (b == null) return '계산 중…';
        // 글자 인식이 덜 끝났으면 TXT·DOCX는 더 커질 수 있다
        final more = ocrPending && (f == SaveFormat.txt || f == SaveFormat.docx);
        return '약 ${_fmtSize(b)}${more ? '+' : ''}';
      }

      /// 이 화질로 고른 형식을 모두 저장할 때의 합계
      int? totalAt(SaveQuality q) {
        var sum = 0;
        for (final f in o.formats) {
          final b = est.bytes(f, q);
          if (b == null) return null;
          sum += b;
        }
        return sum;
      }
      void go(SaveTarget t) {
        if (!zipVisible) o.zip = false; // 안 보이는 ZIP 설정(지난 설정)이 남아 동작을 바꾸지 않게
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
                        size: sizeLabel(f),
                        selected: o.formats.contains(f),
                        // 마지막 하나는 끌 수 없다
                        onTap: () => set(() {
                          if (!o.formats.remove(f) || o.formats.isEmpty) o.formats.add(f);
                        }),
                      ),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Builder(builder: (_) {
                    final t = totalAt(o.quality);
                    return Text(
                        t == null
                            ? '예상 용량 계산 중…'
                            : '${o.formats.length}개 형식 합계 약 ${_fmtSize(t)}${o.zip && zipVisible ? ' (ZIP으로 묶으면 조금 더 작아져요)' : ''}',
                        style: const TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.w700));
                  }),
                ),
                if (o.formats.any((f) => f != SaveFormat.txt && f != SaveFormat.docx)) ...[
                  const SizedBox(height: 22),
                  const _Label('화질'),
                  SegmentedButton<SaveQuality>(
                    showSelectedIcon: false,
                    segments: [
                      for (final q in SaveQuality.values)
                        ButtonSegment(
                          value: q,
                          label: Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(_qualityInfo[q]!.$1),
                            Text(totalAt(q) == null ? '…' : '약 ${_fmtSize(totalAt(q)!)}',
                                style: const TextStyle(fontSize: 10.5, color: AppColors.muted)),
                          ]),
                        ),
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
                if (zipVisible)
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
    })),
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
  const _FormatCard({required this.info, required this.selected, required this.onTap, this.size});

  final (IconData, String, String) info;

  /// 예상 용량 (예: '약 3.2 MB')
  final String? size;
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
          if (size != null) ...[
            const SizedBox(height: 4),
            Text(size!,
                style: TextStyle(
                    color: selected ? AppColors.accent : Colors.white70, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
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
        outs.add(('${o.name}.txt', _txtBytes(pages), 'text/plain'));

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
          // 배경을 제거한 페이지는 PNG에서 투명 배경 (JPG·PDF는 흰 배경)
          final cut = pages[i].cutMask;
          final bytes = ext == 'png' && cut != null
              ? await compute(cutoutPng, (pages[i].jpg, cut, pages[i].quarterTurns, maxSide))
              : maxSide == null && ext == 'jpg'
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
      final gname = bothImages ? name.replaceAll('.', '_') : name.substring(0, name.lastIndexOf('.'));
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

/// TXT 파일 내용. BOM을 붙여야 윈도우 메모장에서도 한글이 깨지지 않는다.
Uint8List _txtBytes(List<ScanPage> pages) {
  final text = [
    for (var i = 0; i < pages.length; i++) '── ${i + 1}페이지 ──\n${pages[i].ocr?.text ?? ''}',
  ].join('\n\n');
  return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
}

/// 파일 크기를 사람이 읽기 쉽게 (KB·MB)
String _fmtSize(int bytes) {
  if (bytes < 1024 * 1024) return '${math.max(1, (bytes / 1024).round())} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
}

/// 저장 용량 어림. TXT·DOCX는 인식된 글자로 정확히, 사진 계열은 [probeSizes]로 잰 한 장을 전체 크기에 비례해 늘린다.
class _SizeEstimate {
  const _SizeEstimate(this.probe, this.pages, this.o);

  final Map<String, int>? probe;
  final List<ScanPage> pages;
  final SaveOptions o;

  /// 예상 바이트 (아직 계산 중이면 null)
  int? bytes(SaveFormat f, SaveQuality q) {
    if (pages.isEmpty) return 0;
    if (f == SaveFormat.txt) return _txtBytes(pages).length;
    if (f == SaveFormat.docx) return _buildDocx(pages).length;
    final pr = probe;
    if (pr == null) return null;
    final qi = SaveQuality.values.indexOf(q);
    final maxSide = _qualityInfo[q]!.$2;
    // 줄인 뒤의 픽셀 수 (표준·작게는 큰 페이지도 같은 크기로 줄어든다)
    int outPix(int w, int h) {
      if (maxSide == null) return w * h;
      final s = math.min(1.0, maxSide / math.max(w, h));
      return (w * s).round() * (h * s).round();
    }

    switch (f) {
      case SaveFormat.jpg:
        return _scaled(pr['jpg$qi']!, outPix, pr).round();
      case SaveFormat.png:
        return _scaled(pr['png$qi']!, outPix, pr).round();
      case SaveFormat.pdf:
        // 사진 + 글자 인식 층·글꼴(부분 내장)은 작다: 약 12KB + 쪽당 1.5KB (실측)
        final extra = o.searchable ? 12000 + 1500 * pages.length : 4000 + 300 * pages.length;
        return (_scaled(pr['jpg$qi']!, outPix, pr) + extra).round();
      case SaveFormat.longImage:
        // 폭 1200으로 이어 붙이고, 너무 길면 전체 높이 3만 픽셀 안으로 줄인다 (stitchLong과 같다)
        var sumRatio = 0.0;
        for (final p in pages) {
          final d = _jpegSize(p.jpg);
          sumRatio += d == null ? pr['rows']! / pr['cols']! : d.$2 / d.$1;
        }
        final w = math.min(1200.0, 30000 / math.max(sumRatio, 0.01));
        final shrink = math.min(1.0, (w / 1200) * (w / 1200));
        return (_scaled(pr['long$qi']!, (pw, ph) => 1200 * (1200 * ph / pw).round(), pr) * shrink).round();
      case SaveFormat.txt:
      case SaveFormat.docx:
        return null; // 위에서 처리
    }
  }

  /// 샘플 한 장의 결과 크기([outSample])를 모든 페이지로 늘린다:
  /// 페이지마다 (줄인 뒤 픽셀 수 비) × (내용 복잡도 = 원본 JPG 바이트/픽셀 비).
  double _scaled(int outSample, int Function(int w, int h) outPix, Map<String, int> pr) {
    final sw = pr['cols']!, sh = pr['rows']!, slen = pr['orig']!;
    final samplePix = outPix(sw, sh), sampleBpp = slen / (sw * sh);
    var total = 0.0;
    for (final p in pages) {
      final d = _jpegSize(p.jpg);
      if (d == null) {
        total += outSample * p.jpg.length / slen; // 크기를 읽을 수 없으면 바이트 비례로
        continue;
      }
      final (w, h) = d;
      total += outSample * (outPix(w, h) / math.max(1, samplePix)) * ((p.jpg.length / (w * h)) / sampleBpp);
    }
    return total;
  }
}

/// JPEG 헤더에서 (너비, 높이)만 읽는다 (전체를 디코딩하지 않는다). JPEG가 아니면 null.
(int, int)? _jpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    // SOF 표지: 정밀도 1바이트 뒤에 높이·너비(각 2바이트)
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
      return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
    }
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      i += 2;
      continue;
    }
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return null;
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
