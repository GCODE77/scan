import 'package:flutter/material.dart';

import 'doc_search.dart';
import 'storage.dart';
import 'theme.dart';

/// 문서의 태그·문서 메모·페이지 메모를 한 화면에서 고친다.
/// 입력하는 즉시 문서 객체에 반영되고, 저장은 화면을 닫은 뒤 부른 쪽에서 한다.
class DocNotesScreen extends StatefulWidget {
  const DocNotesScreen({super.key, required this.doc, this.knownTags = const []});

  final ScanDoc doc;

  /// 다른 문서에서 쓰는 태그 (눌러서 바로 붙이기)
  final List<String> knownTags;

  @override
  State<DocNotesScreen> createState() => _DocNotesScreenState();
}

class _DocNotesScreenState extends State<DocNotesScreen> {
  final _tagCtl = TextEditingController();
  late final TextEditingController _memoCtl = TextEditingController(text: widget.doc.memo);
  late final List<TextEditingController> _pageCtls = [
    for (final p in widget.doc.pages) TextEditingController(text: p.memo),
  ];

  @override
  void dispose() {
    // 입력창에 적고 확인을 누르지 않은 태그도 살린다
    final rest = parseTagInput(_tagCtl.text);
    if (rest.isNotEmpty) widget.doc.tags = applyTagChanges(widget.doc.tags, add: rest);
    _tagCtl.dispose();
    _memoCtl.dispose();
    for (final c in _pageCtls) {
      c.dispose();
    }
    super.dispose();
  }

  void _addTags(String input) {
    final add = parseTagInput(input);
    if (add.isEmpty) return;
    setState(() => widget.doc.tags = applyTagChanges(widget.doc.tags, add: add));
    _tagCtl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final suggestions = [for (final t in widget.knownTags) if (!hasTag(doc.tags, t)) t];
    return Scaffold(
      appBar: AppBar(title: const Text('태그·메모')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const _Head('태그'),
          if (doc.tags.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final t in doc.tags)
                InputChip(
                  label: Text('#$t'),
                  onDeleted: () => setState(() => doc.tags = applyTagChanges(doc.tags, remove: [t])),
                ),
            ]),
          const SizedBox(height: 8),
          TextField(
            controller: _tagCtl,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '태그 추가 (쉼표로 여러 개)',
              prefixIcon: const Icon(Icons.sell_outlined),
              suffixIcon: IconButton(
                  tooltip: '추가', icon: const Icon(Icons.check_rounded), onPressed: () => _addTags(_tagCtl.text)),
            ),
            onSubmitted: _addTags,
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final t in suggestions)
                ActionChip(
                  label: Text('#$t'),
                  onPressed: () => setState(() => doc.tags = applyTagChanges(doc.tags, add: [t])),
                ),
            ]),
          ],
          const SizedBox(height: 24),
          const _Head('문서 메모'),
          TextField(
            controller: _memoCtl,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(hintText: '이 문서에 대한 메모'),
            onChanged: (v) => doc.memo = v,
          ),
          if (doc.pages.isNotEmpty) ...[
            const SizedBox(height: 24),
            const _Head('페이지 메모'),
            for (final (i, p) in doc.pages.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(p.jpg, width: 48, height: 64, fit: BoxFit.cover, cacheWidth: 120),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _pageCtls[i],
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(hintText: '${i + 1}페이지 메모'),
                      onChanged: (v) => p.memo = v,
                    ),
                  ),
                ]),
              ),
          ],
        ],
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.muted)),
      );
}
