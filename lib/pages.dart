import 'package:flutter/material.dart';

import 'ocr.dart';
import 'theme.dart';

/// 페이지 썸네일 목록.
/// 누르면 편집, 길게 누르면 선택 모드 (선택한 페이지만 저장·삭제).
class PageGrid extends StatelessWidget {
  const PageGrid({
    super.key,
    required this.pages,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    this.selectMode = false,
  });

  final bool selectMode;

  final List<ScanPage> pages;
  final Set<ScanPage> selected;
  final void Function(int) onTap;
  final void Function(int) onLongPress;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 120),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, childAspectRatio: 0.72, mainAxisSpacing: 14, crossAxisSpacing: 14),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final p = pages[i];
        final sel = selected.contains(p);
        return GestureDetector(
          onTap: () => onTap(i),
          onLongPress: () => onLongPress(i),
          child: AnimatedScale(
            scale: sel ? .94 : 1,
            duration: const Duration(milliseconds: 150),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: sel ? AppColors.accent : Colors.white10, width: sel ? 2.5 : 1),
                boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(p.jpg, fit: BoxFit.cover, cacheWidth: 300, gaplessPlayback: true),
                // 아래쪽 페이지 번호 + 글자 인식 상태
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black87]),
                    ),
                    child: Row(children: [
                      Text('${i + 1}',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                      const Spacer(),
                      p.ocr == null
                          ? const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white70))
                          : Icon(Icons.text_fields_rounded,
                              size: 14,
                              color: p.ocr!.lines.isEmpty ? Colors.white38 : AppColors.accent),
                    ]),
                  ),
                ),
                if (selectMode || selected.isNotEmpty)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Icon(sel ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                        color: sel ? AppColors.accent : Colors.white,
                        shadows: const [Shadow(blurRadius: 6)]),
                  ),
              ]),
            ),
          ),
        );
      },
    );
  }
}
