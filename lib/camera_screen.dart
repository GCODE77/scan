import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// 촬영 화면. 셔터를 누르면 찍은 사진 경로를 돌려준다.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  String? _error;
  bool _busy = false;
  bool _flash = false;

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
    if (c == null || _busy) return;
    setState(() => _busy = true);
    try {
      final file = await c.takePicture();
      if (mounted) Navigator.pop(context, file.path);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFlash() async {
    _flash = !_flash;
    await _controller?.setFlashMode(_flash ? FlashMode.torch : FlashMode.off);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _error != null
                    ? Text(_error!, style: const TextStyle(color: Colors.white))
                    : c == null
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: 1 / c.value.aspectRatio,
                            child: Stack(fit: StackFit.expand, children: [
                              CameraPreview(c),
                              const _Guide(),
                            ]),
                          ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 30),
                    onPressed: () => Navigator.pop(context),
                  ),
                  GestureDetector(
                    onTap: _shoot,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 5),
                        color: _busy ? Colors.grey : Colors.white24,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(_flash ? Icons.flash_on : Icons.flash_off,
                        color: Colors.white, size: 30),
                    onPressed: _toggleFlash,
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

/// 페이지를 화면 안에 맞추도록 돕는 안내선.
class _Guide extends StatelessWidget {
  const _Guide();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white38, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
