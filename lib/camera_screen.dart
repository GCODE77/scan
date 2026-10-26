import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'ocr.dart';
import 'scanner.dart';
import 'theme.dart';

/// 연속 촬영 화면. 셔터를 누를 때마다 뒤에서 페이지를 자동 인식·펴기 한다.
/// '완료'를 누르면 만들어진 페이지 목록을 돌려준다.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.galleryFirst = false});

  /// 열자마자 갤러리에서 사진 고르기
  final bool galleryFirst;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  String? _error;
  FlashMode _flash = FlashMode.off;
  bool _flashEffect = false;
  bool _pressed = false;

  /// 화면을 누른 곳 (초점 표시용, 0~1 비율)
  Offset? _focusAt;
  int _focusSeq = 0;
  final List<ScanPage> _pages = [];
  int _processing = 0;
  Future<void> _queue = Future.value();

  // ── 실시간 윤곽 + 자동 셔터 ──
  /// 자동 셔터 켜기/끄기 (앱을 켜 있는 동안 기억, 기본 끔)
  static bool _auto = false;

  /// 미리보기에서 찾은 종이 윤곽 (화면 기준 0~1)
  List<Offset>? _live;
  bool _analyzing = false;
  DateTime _lastFrame = DateTime(0);
  Uint8List? _prevSig;

  /// 연속으로 흔들림 없던 횟수 (자동 셔터 진행도)
  int _steady = 0;
  static const _steadyNeed = 4;

  /// 한 장 찍은 뒤에는 화면이 크게 바뀌어야(페이지 넘김) 다음 장을 찍는다
  bool _armed = true;
  Uint8List? _shotSig;
  bool _shooting = false;

  Future<void> _startStream() async {
    final c = _controller;
    if (c == null || c.value.isStreamingImages) return;
    try {
      await c.startImageStream(_onFrame);
    } catch (_) {
      // 미리보기 분석을 못 하는 기기면 그냥 수동 촬영
    }
  }

  Future<void> _stopStream() async {
    final c = _controller;
    if (c != null && c.value.isStreamingImages) {
      try {
        await c.stopImageStream();
      } catch (_) {}
    }
  }

  static double _sigDiff(Uint8List a, Uint8List b) {
    var d = 0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      d += (a[i] - b[i]).abs();
    }
    return d / a.length;
  }

  void _onFrame(CameraImage img) {
    // 1초에 4번 정도만, 앞 분석이 끝났을 때만
    final now = DateTime.now();
    if (_analyzing || _shooting || now.difference(_lastFrame).inMilliseconds < 250) return;
    _lastFrame = now;
    _analyzing = true;
    final pl = img.planes.first;
    final sensor = _controller?.description.sensorOrientation ?? 90;
    compute(liveDetect, (Uint8List.fromList(pl.bytes), img.width, img.height, pl.bytesPerRow, sensor))
        .then((r) {
      if (!mounted) return;
      final (quad, sig) = r;
      final prev = _live, prevSig = _prevSig;
      _prevSig = sig;
      // 흔들림: 윤곽 모서리 이동량 + 장면 밝기 변화
      final motion = prevSig == null ? 99.0 : _sigDiff(sig, prevSig);
      var moved = 1.0;
      if (quad != null && prev != null) {
        moved = 0;
        for (var i = 0; i < 4; i++) {
          moved = math.max(moved, (quad[i] - prev[i]).distance);
        }
      }
      // 찍은 뒤 페이지를 넘기는 등 화면이 크게 바뀌면 다음 장 준비
      if (!_armed && _shotSig != null && _sigDiff(sig, _shotSig!) > 12) _armed = true;
      final steadyNow = quad != null && moved < 0.015 && motion < 3;
      setState(() {
        _live = quad;
        _steady = steadyNow ? _steady + 1 : 0;
      });
      if (_auto && _armed && _steady >= _steadyNeed) {
        _shotSig = sig;
        _armed = false;
        _steady = 0;
        _shoot();
      }
    }).whenComplete(() => _analyzing = false);
  }

  @override
  void initState() {
    super.initState();
    _init();
    if (widget.galleryFirst) WidgetsBinding.instance.addPostFrameCallback((_) => _pickFromGallery());
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(back, ResolutionPreset.max, enableAudio: false);
      await c.initialize();
      await c.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() => _controller = c);
      _startStream();
    } catch (e) {
      setState(() => _error = '카메라를 열 수 없습니다: $e');
    }
  }

  @override
  void dispose() {
    _stopStream();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || c.value.isTakingPicture || _shooting) return;
    _shooting = true;
    HapticFeedback.mediumImpact();
    // 미리보기 분석을 잠시 멈추고 찍는다 (기기에 따라 동시에 못 함)
    await _stopStream();
    late final XFile file;
    try {
      file = await c.takePicture();
    } finally {
      _shooting = false;
      _startStream();
    }
    setState(() => _flashEffect = true);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _flashEffect = false);
    });
    _process(file.path, deleteAfter: true);
  }

  /// 갤러리에서 사진 여러 장 불러오기 → 찍은 사진과 똑같이 자동 인식·펴기
  Future<void> _pickFromGallery() async {
    final picked = await ImagePicker().pickMultiImage(requestFullMetadata: false);
    for (final f in picked) {
      _process(f.path, deleteAfter: false);
    }
  }

  void _process(String path, {required bool deleteAfter}) {
    setState(() => _processing++);
    // 촬영은 바로 다음 장으로, 인식·펴기는 순서대로 뒤에서
    _queue = _queue.then((_) async {
      try {
        // 사진 한 장에 문서가 여러 장이면 각각 페이지로
        for (final (det, flats) in await compute(autoScan, path)) {
          for (var i = 0; i < flats.length; i++) {
            _pages.add(ScanPage(det: det, shape: det.shape, part: i, flat: flats[i]));
          }
        }
      } catch (e) {
        // 한 장이 실패해도 다음 장은 계속 (예: 읽을 수 없는 형식)
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('사진 한 장을 처리하지 못했습니다: $e')));
        }
      } finally {
        if (deleteAfter) File(path).delete().ignore();
        if (mounted) setState(() => _processing--);
      }
    });
  }

  Future<void> _finish() async {
    HapticFeedback.lightImpact();
    if (_processing > 0) await _queue;
    if (mounted) Navigator.pop(context, _pages);
  }

  static const _flashModes = [FlashMode.off, FlashMode.auto, FlashMode.always, FlashMode.torch];
  static const _flashInfo = {
    FlashMode.off: (Icons.flash_off_rounded, '플래시 끔'),
    FlashMode.auto: (Icons.flash_auto_rounded, '플래시 자동'),
    FlashMode.always: (Icons.flash_on_rounded, '플래시 켬'),
    FlashMode.torch: (Icons.highlight_rounded, '조명 계속 켬'),
  };

  Future<void> _cycleFlash() async {
    final next = _flashModes[(_flashModes.indexOf(_flash) + 1) % _flashModes.length];
    try {
      await _controller?.setFlashMode(next);
      setState(() => _flash = next);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
              content: Text(_flashInfo[next]!.$2), duration: const Duration(milliseconds: 900)));
      }
    } catch (_) {}
  }

  /// 누른 곳에 초점·밝기 맞추기
  Future<void> _focus(Offset rel) async {
    final c = _controller;
    if (c == null) return;
    final seq = ++_focusSeq;
    setState(() => _focusAt = rel);
    try {
      await c.setFocusMode(FocusMode.auto);
      await c.setFocusPoint(rel);
      await c.setExposurePoint(rel);
    } catch (_) {
      // 초점 지정이 안 되는 카메라도 있다
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (mounted && seq == _focusSeq) setState(() => _focusAt = null);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final count = _pages.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              const Spacer(),
              // 자동 셔터 켜기/끄기
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _auto = !_auto;
                    _armed = true;
                    _steady = 0;
                  });
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                        duration: const Duration(seconds: 2),
                        content: Text(_auto
                            ? '자동 촬영 켬 · 종이를 맞추고 잠깐 멈추면 찍혀요. 책은 넘기고 멈추면 다음 장을 찍어요'
                            : '자동 촬영 끔')));
                },
                icon: Icon(_auto ? Icons.motion_photos_auto_rounded : Icons.motion_photos_off_outlined,
                    color: _auto ? AppColors.accent : Colors.white),
                label: Text(_auto ? '자동 촬영' : '자동 끔',
                    style: TextStyle(color: _auto ? AppColors.accent : Colors.white)),
              ),
              IconButton(
                icon: Icon(_flashInfo[_flash]!.$1,
                    color: _flash == FlashMode.off ? Colors.white : AppColors.accent),
                tooltip: _flashInfo[_flash]!.$2,
                onPressed: _cycleFlash,
              ),
            ]),
            Expanded(
              child: Center(
                child: _error != null
                    ? Text(_error!, style: const TextStyle(color: Colors.white))
                    : c == null
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: 1 / c.value.aspectRatio,
                            child: LayoutBuilder(builder: (context, box) => GestureDetector(
                              onTapUp: (e) => _focus(Offset(e.localPosition.dx / box.maxWidth,
                                  e.localPosition.dy / box.maxHeight)),
                              child: Stack(fit: StackFit.expand, children: [
                              CameraPreview(c),
                              // 문서를 맞추는 네모 점선 안내 (윤곽을 찾으면 윤곽으로 바뀐다)
                              if (_live == null)
                                const IgnorePointer(child: CustomPaint(painter: _GuidePainter())),
                              if (_live != null)
                                IgnorePointer(
                                  child: CustomPaint(
                                    painter: _LivePainter(
                                        _live!, _auto && _armed ? _steady / _steadyNeed : -1),
                                  ),
                                ),
                              if (_focusAt != null)
                                Positioned(
                                  left: _focusAt!.dx * box.maxWidth - 36,
                                  top: _focusAt!.dy * box.maxHeight - 36,
                                  child: TweenAnimationBuilder<double>(
                                    key: ValueKey(_focusSeq),
                                    tween: Tween(begin: 1.5, end: 1),
                                    duration: const Duration(milliseconds: 250),
                                    builder: (_, v, _) => Transform.scale(
                                      scale: v,
                                      child: Container(
                                        width: 72,
                                        height: 72,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(color: AppColors.accent, width: 2),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              AnimatedOpacity(
                                opacity: _flashEffect ? 0.7 : 0,
                                duration: const Duration(milliseconds: 100),
                                child: const ColoredBox(color: Colors.white),
                              ),
                            ]),
                            )),
                          ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('셔터만 누르세요 · 여러 장도 한 번에 · 화면을 누르면 초점',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            // 아래 줄: [갤러리] [셔터] [찍은 페이지 = 완료]  (삼성 카메라 배치)
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BottomSlot(
                    label: '갤러리',
                    onTap: _pickFromGallery,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white12,
                        border: Border.all(color: Colors.white38),
                      ),
                      child: const Icon(Icons.photo_library_rounded, color: Colors.white, size: 26),
                    ),
                  ),
                  const Spacer(),
                  // 셔터: 누르는 동안 살짝 작아진다
                  GestureDetector(
                    onTapDown: (_) => setState(() => _pressed = true),
                    onTapUp: (_) => setState(() => _pressed = false),
                    onTapCancel: () => setState(() => _pressed = false),
                    onTap: _shoot,
                    child: AnimatedScale(
                      scale: _pressed ? 0.88 : 1,
                      duration: const Duration(milliseconds: 90),
                      child: Container(
                        width: 78,
                        height: 78,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                        ),
                        child: const DecoratedBox(
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  _BottomSlot(
                    label: count + _processing == 0 ? '' : '완료',
                    onTap: count + _processing == 0 ? null : _finish,
                    child: count == 0 && _processing == 0
                        ? const SizedBox()
                        : Stack(clipBehavior: Clip.none, children: [
                            Positioned.fill(
                              child: Container(
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.accent, width: 2),
                                ),
                                child: count == 0
                                    ? null
                                    : Image.memory(_pages.last.jpg, fit: BoxFit.cover, cacheWidth: 150),
                              ),
                            ),
                            if (_processing > 0)
                              const Positioned.fill(
                                  child: Center(
                                      child: SizedBox(
                                          width: 24,
                                          height: 24,
                                          child: CircularProgressIndicator(strokeWidth: 2.5)))),
                            if (count > 0)
                              Positioned(
                                right: -8,
                                top: -8,
                                child: CircleAvatar(
                                    radius: 12,
                                    backgroundColor: AppColors.accent,
                                    child: Text('$count',
                                        style: const TextStyle(
                                            fontSize: 12, color: Color(0xFF00281F), fontWeight: FontWeight.w700))),
                              ),
                          ]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 아래 줄 양옆 버튼 (아이콘 + 이름)
class _BottomSlot extends StatelessWidget {
  const _BottomSlot({required this.label, required this.child, this.onTap});

  final String label;
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(children: [
          SizedBox(width: 56, height: 56, child: child),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// 촬영 안내: 네모 점선 + 모서리 꺾쇠
class _GuidePainter extends CustomPainter {
  const _GuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(size.width * .07, size.height * .06, size.width * .93, size.height * .94);
    final dash = Paint()
      ..color = Colors.white.withValues(alpha: .7)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    // 점선 테두리
    void dashed(Offset a, Offset b) {
      final d = b - a, len = d.distance, u = d / len;
      for (var t = 0.0; t < len; t += 14) {
        canvas.drawLine(a + u * t, a + u * math.min(t + 8, len), dash);
      }
    }

    dashed(r.topLeft, r.topRight);
    dashed(r.topRight, r.bottomRight);
    dashed(r.bottomRight, r.bottomLeft);
    dashed(r.bottomLeft, r.topLeft);
    // 모서리 꺾쇠 (민트)
    final corner = Paint()
      ..color = const Color(0xFF4FE3C1)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const l = 28.0;
    for (final (p, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomRight, -1.0, -1.0),
      (r.bottomLeft, 1.0, -1.0),
    ]) {
      canvas.drawPath(
          Path()
            ..moveTo(p.dx, p.dy + dy * l)
            ..lineTo(p.dx, p.dy)
            ..lineTo(p.dx + dx * l, p.dy),
          corner);
    }
  }

  @override
  bool shouldRepaint(_GuidePainter old) => false;
}

/// 실시간 종이 윤곽. [progress] 0~1이면 자동 촬영까지 남은 정도를 함께 보여 준다 (음수면 표시 안 함).
class _LivePainter extends CustomPainter {
  _LivePainter(this.quad, this.progress);

  final List<Offset> quad;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = [for (final p in quad) Offset(p.dx * size.width, p.dy * size.height)];
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(path, Paint()..color = const Color(0xFF4FE3C1).withValues(alpha: .18));
    canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF4FE3C1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round);
    for (final p in pts) {
      canvas.drawCircle(p, 6, Paint()..color = const Color(0xFF4FE3C1));
    }
    if (progress >= 0) {
      // 가운데 원: 채워지면 찍힌다
      final c = pts.reduce((a, b) => a + b) / 4;
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(c, 34, ring..color = Colors.white24);
      canvas.drawArc(Rect.fromCircle(center: c, radius: 34), -math.pi / 2,
          2 * math.pi * progress.clamp(0.0, 1.0), false, ring..color = const Color(0xFF4FE3C1));
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
