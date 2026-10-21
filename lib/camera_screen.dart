import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'ocr.dart';
import 'scanner.dart';
import 'theme.dart';

/// 연속 촬영 화면. 셔터를 누를 때마다 뒤에서 페이지를 자동 인식·펴기 한다.
/// '완료'를 누르면 만들어진 페이지 목록을 돌려준다.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  String? _error;
  FlashMode _flash = FlashMode.off;
  bool _flashEffect = false;

  /// 화면을 누른 곳 (초점 표시용, 0~1 비율)
  Offset? _focusAt;
  int _focusSeq = 0;
  final List<ScanPage> _pages = [];
  int _processing = 0;
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    _init();
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
    } catch (e) {
      setState(() => _error = '카메라를 열 수 없습니다: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _shoot() async {
    final c = _controller;
    if (c == null || c.value.isTakingPicture) return;
    final file = await c.takePicture();
    setState(() {
      _processing++;
      _flashEffect = true;
    });
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _flashEffect = false);
    });
    // 촬영은 바로 다음 장으로, 인식·펴기는 순서대로 뒤에서
    _queue = _queue.then((_) async {
      try {
        final (det, flats) = await compute(autoScan, file.path);
        for (var i = 0; i < flats.length; i++) {
          _pages.add(ScanPage(det: det, shape: det.shape, part: i, flat: flats[i]));
        }
      } finally {
        File(file.path).delete().ignore();
        if (mounted) setState(() => _processing--);
      }
    });
  }

  Future<void> _finish() async {
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
              child: Text('책을 화면에 담고 셔터만 누르세요 · 화면을 누르면 초점',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
              child: Row(
                children: [
                  // 마지막 페이지 썸네일 + 장 수
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: count == 0 && _processing == 0
                        ? null
                        : Stack(clipBehavior: Clip.none, children: [
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2)),
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
                                        style: const TextStyle(fontSize: 12, color: Color(0xFF00281F), fontWeight: FontWeight.w700))),
                              ),
                          ]),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _shoot,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 5),
                        color: Colors.white24,
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 64,
                    child: count + _processing == 0
                        ? null
                        : FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: AppColors.accent, padding: EdgeInsets.zero, minimumSize: const Size(64, 48)),
                            onPressed: _finish,
                            child: const Icon(Icons.check),
                          ),
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
