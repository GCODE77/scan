import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'scanner.dart';

/// 인식된 한 줄: 글자와 페이지 이미지 안의 위치(픽셀).
class OcrLine {
  OcrLine(this.text, this.box);

  final String text;
  final Rect box;
}

/// 한 페이지의 OCR 결과.
class OcrResult {
  OcrResult(this.lines);

  final List<OcrLine> lines;

  String get text => lines.map((l) => l.text).join('\n');
}

/// 스캔된 페이지 한 장.
/// [flat]은 편 원본, [jpg]는 필터·회전을 입힌 최종 결과.
class ScanPage {
  ScanPage({required this.det, required this.shape, required this.part, required this.flat, String? id})
      : jpg = flat,
        id = id ?? newId();

  /// 보관함 파일 이름에 쓰는 고유 번호
  final String id;

  /// 촬영 원본과 검출 결과 (자르기 화면에서 다시 쓴다)
  final Detection det;
  PageShape shape;

  /// 양면 사진이면 0=왼쪽, 1=오른쪽. 한 쪽이면 0.
  int part;
  Uint8List flat;
  ScanMode mode = ScanMode.original;
  int quarterTurns = 0;
  Uint8List jpg;
  OcrResult? ocr;

  /// 필터·회전을 다시 입힌다. 글자 인식 결과는 위치가 바뀌므로 지운다.
  Future<void> render() async {
    jpg = mode == ScanMode.original && quarterTurns % 4 == 0
        ? flat
        : await compute(renderPage, (flat, mode, quarterTurns, null));
    ocr = null;
  }
}

var _idSeq = 0;

String newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idSeq++).toRadixString(36)}';

/// 한국어 인식기. 한글과 영어(라틴 문자)를 함께 읽는다. 모든 처리는 휴대폰 안에서.
class Ocr {
  static final _recognizer = TextRecognizer(script: TextRecognitionScript.korean);
  static var _seq = 0;

  static Future<OcrResult> recognize(Uint8List jpg) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ocr_${_seq++}.jpg');
    await file.writeAsBytes(jpg);
    try {
      final result = await _recognizer.processImage(InputImage.fromFilePath(file.path));
      return OcrResult([
        for (final block in result.blocks)
          for (final line in block.lines) OcrLine(line.text, line.boundingBox),
      ]);
    } finally {
      file.delete().ignore();
    }
  }
}
