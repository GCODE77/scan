import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

const kCopyright = '© 2026 GLORY KIM. All rights reserved.';
const _releasesPage = 'https://github.com/GCODE77/scan/releases/latest';

/// 새 버전 정보
class Release {
  Release(this.version, this.notes, this.apkUrl);

  final String version;
  final String notes;
  final String apkUrl;
}

/// GitHub 최신 릴리스를 확인하고, 새 버전이 있으면 알려서 받아 설치하게 한다.
class Updater {
  static const _api = 'https://api.github.com/repos/GCODE77/scan/releases/latest';

  static Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// GitHub 최신 릴리스 (확인 실패면 null)
  static Future<Release?> latest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(_api));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      final apk = (j['assets'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((a) => (a['name'] as String).endsWith('.apk'), orElse: () => {});
      final url = apk['browser_download_url'] as String?;
      if (url == null) return null;
      return Release((j['tag_name'] as String).replaceFirst('v', ''), (j['body'] as String?) ?? '', url);
    } catch (e) {
      debugPrint('업데이트 확인 실패: $e');
      return null;
    } finally {
      client.close();
    }
  }

  static bool isNewer(String a, String b) {
    List<int> parse(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
      if (p != q) return p > q;
    }
    return false;
  }

  /// 새 버전이 있으면 알림 창. [manual]이면 최신일 때·실패할 때도 알려 준다.
  static Future<void> checkAndPrompt(BuildContext context, {bool manual = false}) async {
    final current = await currentVersion();
    final rel = await latest();
    if (!context.mounted) return;
    if (rel == null || !isNewer(rel.version, current)) {
      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(rel == null ? '업데이트를 확인하지 못했습니다 (인터넷 연결 확인)' : '최신 버전입니다 (v$current)')));
      }
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.system_update_rounded, color: AppColors.accent, size: 36),
        title: Text('새 버전 v${rel.version}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('지금 버전 v$current → 새 버전 v${rel.version}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Text(rel.notes.isEmpty ? '새 버전이 나왔습니다.' : rel.notes,
                style: const TextStyle(color: AppColors.muted, height: 1.5)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('나중에')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('업데이트')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DownloadDialog(rel: rel),
      );
    }
  }

  /// 앱 정보: 버전, 저작권, 업데이트 확인
  static Future<void> showAbout(BuildContext context) async {
    final current = await currentVersion();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        icon: ShaderMask(
          shaderCallback: AppColors.gradient.createShader,
          child: const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 48),
        ),
        title: const Text('북스캔'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('버전 v$current', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('책을 스캐너처럼 · 굴곡 펴기 · 한국어·영어 OCR',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 18),
          const Text(kCopyright, style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('닫기')),
          FilledButton.icon(
            icon: const Icon(Icons.system_update_rounded, size: 20),
            label: const Text('업데이트 확인'),
            onPressed: () {
              Navigator.pop(d);
              checkAndPrompt(context, manual: true);
            },
          ),
        ],
      ),
    );
  }
}

/// 내려받기 진행률 → 시스템 설치 화면. 실패하면 이유와 다른 방법을 알려 준다.
class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.rel});

  final Release rel;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double? _progress;
  bool _installing = false;
  String? _error;
  bool _needPermission = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _progress = null;
      _installing = false;
      _error = null;
      _needPermission = false;
    });
    try {
      OtaUpdate()
          .execute(widget.rel.apkUrl, destinationFilename: 'BookScan-${widget.rel.version}.apk')
          .listen(
        (e) {
          if (!mounted) return;
          switch (e.status) {
            case OtaStatus.DOWNLOADING:
              setState(() => _progress = (double.tryParse(e.value ?? '') ?? 0) / 100);
            case OtaStatus.INSTALLING:
            case OtaStatus.INSTALLATION_DONE:
              setState(() => _installing = true);
            case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
              setState(() {
                _needPermission = true;
                _error = '앱 설치 권한이 필요합니다.\n\n휴대폰 설정 → 애플리케이션 → 북스캔 → '
                    '"출처를 알 수 없는 앱 설치"를 허용한 뒤 다시 시도를 눌러 주세요.';
              });
            default:
              setState(() => _error = '앱 안에서 설치하지 못했습니다 (${e.status.name}).\n'
                  '"웹에서 받기"로 내려받아 설치해 주세요.');
          }
        },
        onError: (e) {
          if (mounted) setState(() => _error = '내려받기 실패: $e');
        },
      );
    } catch (e) {
      setState(() => _error = '내려받기 실패: $e');
    }
  }

  Future<void> _openWeb() async {
    await launchUrl(Uri.parse(_releasesPage), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final String title;
    final Widget body;
    if (_error != null) {
      title = '업데이트하지 못했습니다';
      body = Text(_error!, style: const TextStyle(height: 1.5));
    } else if (_installing) {
      title = '설치 화면에서 \'업데이트\'를 눌러 주세요';
      body = const Text(
        '설치 화면이 보이지 않거나 설치가 취소되었다면\n'
        '"다시 시도" 또는 "웹에서 받기"를 눌러 주세요.\n\n'
        '처음이면 "출처를 알 수 없는 앱 설치" 허용 화면이 먼저 나올 수 있습니다. '
        '허용한 뒤 돌아와서 "다시 시도"를 눌러 주세요.',
        style: TextStyle(height: 1.5, color: AppColors.muted),
      );
    } else {
      title = 'v${widget.rel.version} 내려받는 중…';
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(value: _progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
        const SizedBox(height: 12),
        Text(_progress == null ? '준비 중' : '${(_progress! * 100).round()}%'),
      ]);
    }
    final done = _error != null || _installing;
    return AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 18)),
      content: body,
      actions: [
        if (done) TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기')),
        if (done) TextButton(onPressed: _openWeb, child: const Text('웹에서 받기')),
        if (done)
          FilledButton(
            onPressed: _needPermission || _error != null || _installing ? _start : null,
            child: const Text('다시 시도'),
          ),
      ],
    );
  }
}
