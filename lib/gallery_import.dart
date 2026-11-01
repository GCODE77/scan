import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'ocr.dart';
import 'scanner.dart';
import 'theme.dart';

/// 갤러리에서 사진 여러 장을 골라 찍은 사진과 똑같이 자동 인식·펴기까지 한 뒤 페이지들로 돌려준다.
/// 카메라 화면을 거치지 않으므로 바로 편집 화면으로 넘어갈 수 있다. 고르지 않았으면 빈 목록.
Future<List<ScanPage>> pickAndScan(BuildContext context) async {
  final picked = await ImagePicker().pickMultiImage(requestFullMetadata: false);
  if (picked.isEmpty || !context.mounted) return [];

  final done = ValueNotifier<int>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surface,
        content: ValueListenableBuilder<int>(
          valueListenable: done,
          builder: (_, n, _) => Row(children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 18),
            Expanded(child: Text('사진 ${(n + 1).clamp(1, picked.length)} / ${picked.length}장 인식 중…')),
          ]),
        ),
      ),
    ),
  );

  final pages = <ScanPage>[];
  var failed = 0;
  for (final f in picked) {
    try {
      // 사진 한 장에 문서가 여러 장이면 각각 페이지로
      for (final (det, flats) in await compute(autoScan, f.path)) {
        for (var i = 0; i < flats.length; i++) {
          pages.add(ScanPage(det: det, shape: det.shape, part: i, flat: flats[i]));
        }
      }
    } catch (e) {
      failed++; // 한 장이 실패해도 다음 장은 계속 (예: 읽을 수 없는 형식)
      debugPrint('사진 처리 실패: $e');
    }
    done.value++;
  }
  done.dispose();

  if (!context.mounted) return pages;
  Navigator.of(context, rootNavigator: true).pop(); // 진행 창 닫기
  if (failed > 0) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('사진 $failed장을 처리하지 못했습니다')));
  }
  return pages;
}
