import 'package:flutter/material.dart';

import 'ocr.dart';

/// 페이지 썸네일 목록.
/// 누르면 편집, 길게 누르면 선택 모드 (선택한 페이지만 저장·삭제).
class PageGrid extends StatelessWidget {
  const PageGrid({
    super.key,
    required this.pages,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final List<ScanPage> pages;
  final Set<ScanPage> selected;
  final void Function(int) onTap;
  final void Function(int) onLongPress;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 100),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3, childAspectRatio: 0.7, mainAxisSpacing: 10, crossAxisSpacing: 10),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final p = pages[i];
        final sel = selected.contains(p);
        return GestureDetector(
          onTap: () => onTap(i),
          onLongPress: () => onLongPress(i),
          child: Column(children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                Container(
                  decoration: BoxDecoration(
                      border: Border.all(
                          color: sel ? Colors.teal : Colors.black12, width: sel ? 3 : 1),
                      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
                  child: Image.memory(p.jpg, fit: BoxFit.cover, cacheWidth: 300, gaplessPlayback: true),
                ),
                if (selected.isNotEmpty)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Icon(sel ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: sel ? Colors.teal : Colors.white,
                        shadows: const [Shadow(blurRadius: 4)]),
                  ),
              ]),
            ),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('${i + 1}'),
              const SizedBox(width: 4),
              p.ocr == null
                  ? const SizedBox(
                      width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5))
                  : Icon(Icons.text_fields,
                      size: 14, color: p.ocr!.lines.isEmpty ? Colors.grey : Colors.indigo),
            ]),
          ]),
        );
      },
    );
  }
}
