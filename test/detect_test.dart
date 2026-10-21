// 페이지 검출 시험: 사진 경로를 BOOKSCAN_TEST_IMAGES(;로 구분)로 넘긴다.
import 'dart:io';

import 'package:book_scan/scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final paths = (Platform.environment['BOOKSCAN_TEST_IMAGES'] ?? '').split(';').where((p) => p.isNotEmpty);
  for (final path in paths) {
    test('detect $path', () async {
      final d = await detectPage(path);
      String f(Offset o) => '(${o.dx.round()},${o.dy.round()})';
      // ignore: avoid_print
      print('$path ${d.width}x${d.height} found=${d.found} spread=${d.shape.spread}\n'
          ' top=${d.shape.top.map(f).join(' ')}\n bot=${d.shape.bottom.map(f).join(' ')}');
      final flats = await warpFlat((d.jpg, d.shape));
      await File('$path.flat.jpg').writeAsBytes(flats.first);
    });
  }
}
