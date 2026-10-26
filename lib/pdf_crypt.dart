import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pdf/pdf.dart';
// 암호화 객체를 만들려면 내부 형식 클래스가 필요하다
// ignore: implementation_imports
import 'package:pdf/src/priv.dart';

/// PDF 표준 암호 (Standard Security Handler, Revision 3, RC4 128비트).
/// 어떤 PDF 뷰어에서든 열 때 암호를 묻는다.
class PdfPasswordEncryption extends PdfEncryption {
  PdfPasswordEncryption(PdfDocument doc, String userPassword, {String? ownerPassword})
      : super(doc) {
    final id = doc.documentID;
    final user = _pad(userPassword);
    final owner = _pad(ownerPassword ?? userPassword);

    // O 값: 소유자 암호로 만든 키로 사용자 암호를 감싼다
    var h = md5.convert(owner).bytes;
    for (var i = 0; i < 50; i++) {
      h = md5.convert(h).bytes;
    }
    final oKey = h.sublist(0, 16);
    var o = _rc4(oKey, user);
    for (var i = 1; i <= 19; i++) {
      o = _rc4([for (final b in oKey) b ^ i], o);
    }

    // 문서 암호 키
    final p = _p;
    final pBytes = [p & 0xff, (p >> 8) & 0xff, (p >> 16) & 0xff, (p >> 24) & 0xff];
    var k = md5.convert([...user, ...o, ...pBytes, ...id]).bytes;
    for (var i = 0; i < 50; i++) {
      k = md5.convert(k.sublist(0, 16)).bytes;
    }
    _key = k.sublist(0, 16);

    // U 값
    var u = _rc4(_key, md5.convert([..._padding, ...id]).bytes);
    for (var i = 1; i <= 19; i++) {
      u = _rc4([for (final b in _key) b ^ i], u);
    }
    u = [...u, ...List.filled(16, 0)];

    params['/Filter'] = const PdfName('/Standard');
    params['/V'] = const PdfNum(2);
    params['/R'] = const PdfNum(3);
    params['/Length'] = const PdfNum(128);
    params['/P'] = const PdfNum(_p);
    params['/O'] = PdfString(Uint8List.fromList(o), format: PdfStringFormat.binary, encrypted: false);
    params['/U'] = PdfString(Uint8List.fromList(u), format: PdfStringFormat.binary, encrypted: false);
  }

  /// 권한: 모두 허용 (인쇄·복사 등)
  static const _p = -4;

  late final List<int> _key;

  static const _padding = [
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08, //
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
  ];

  static List<int> _pad(String pw) {
    final b = latin1.encode(pw.runes.where((r) => r < 256).map(String.fromCharCode).join());
    return [...b.take(32), ..._padding.take(32 - b.take(32).length)];
  }

  static List<int> _rc4(List<int> key, List<int> data) {
    final s = List<int>.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + s[i] + key[i % key.length]) & 0xff;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    final out = List<int>.filled(data.length, 0);
    var i = 0;
    j = 0;
    for (var n = 0; n < data.length; n++) {
      i = (i + 1) & 0xff;
      j = (j + s[i]) & 0xff;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[n] = data[n] ^ s[(s[i] + s[j]) & 0xff];
    }
    return out;
  }

  @override
  Uint8List encrypt(Uint8List input, PdfObjectBase object) {
    // 객체마다 키: 문서 키 + 객체 번호(3바이트) + 세대(2바이트)
    final n = object.objser, g = object.objgen;
    final k = md5
        .convert([..._key, n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, g & 0xff, (g >> 8) & 0xff])
        .bytes
        .sublist(0, 16);
    return Uint8List.fromList(_rc4(k, input));
  }
}
