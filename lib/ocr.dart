import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'scanner.dart';
import 'signature.dart';

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

  /// 필터 강도 0~1
  double strength = 1;

  /// 자동 정리(손가락·그림자·빛 반사)를 했는지, 되돌리기용 원래 이미지 (앱을 켜 있는 동안만)
  bool cleaned = false;
  Uint8List? rawFlat;

  /// 페이지에 얹은 서명들
  final List<Stamp> stamps = [];
  Uint8List jpg;
  OcrResult? ocr;

  /// 필터·회전을 다시 입힌다. 글자 인식 결과는 위치가 바뀌므로 지운다.
  Future<void> render() async {
    var out = mode == ScanMode.original && quarterTurns % 4 == 0
        ? flat
        : await compute(renderPage, (flat, mode, quarterTurns, null, strength));
    if (stamps.isNotEmpty) {
      out = await compute(stampPage, (
        out,
        [for (final s in stamps) (s.png, s.rect.left, s.rect.top, s.rect.width, s.rect.height, s.turns)],
      ));
    }
    jpg = out;
    ocr = null;
  }
}

var _idSeq = 0;

String newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idSeq++).toRadixString(36)}';

/// 한국어 인식기. 한글과 영어(라틴 문자)를 함께 읽는다. 모든 처리는 휴대폰 안에서.
class Ocr {
  static final _recognizer = TextRecognizer(script: TextRecognitionScript.korean);
  static var _seq = 0;

  /// 페이지 글자 인식. 필터를 입힌 사진 대신 '그림자 없앤 회색' 이미지로 읽어서 정확도를 높이고,
  /// 결과 위치는 페이지 이미지(jpg) 좌표로 돌려준다.
  static Future<OcrResult> recognize(ScanPage page) async {
    final (img, scale) = await compute(ocrImage, (page.flat, page.quarterTurns));
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ocr_${_seq++}.png');
    await file.writeAsBytes(img);
    try {
      final result = await _recognizer.processImage(InputImage.fromFilePath(file.path));
      Rect back(Rect r) =>
          Rect.fromLTRB(r.left / scale, r.top / scale, r.right / scale, r.bottom / scale);
      return OcrResult([
        for (final block in result.blocks)
          for (final line in block.lines)
            if (line.text.trim().isNotEmpty) OcrLine(line.text, back(line.boundingBox)),
      ]);
    } finally {
      file.delete().ignore();
    }
  }
}
