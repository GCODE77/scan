import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'theme.dart';

/// GitHub 최신 릴리스를 확인하고, 새 버전이 있으면 알려서 받아 설치하게 한다.
class Updater {
  static const _api = 'https://api.github.com/repos/GCODE77/scan/releases/latest';

  /// 새 버전이 있으면 (버전, 변경 내용, APK 주소). 없거나 확인 실패면 null.
  static Future<(String, String, String)?> check() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(_api));
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close();
      if (res.statusCode != 200) return null;
      final j = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
      client.close();

      final latest = (j['tag_name'] as String).replaceFirst('v', '');
      final current = (await PackageInfo.fromPlatform()).version;
      if (!_newer(latest, current)) return null;
      final apk = (j['assets'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((a) => (a['name'] as String).endsWith('.apk'), orElse: () => {});
      final url = apk['browser_download_url'] as String?;
      if (url == null) return null;
      return (latest, (j['body'] as String?) ?? '', url);
    } catch (e) {
      debugPrint('업데이트 확인 실패: $e');
      return null;
    }
  }

  static bool _newer(String a, String b) {
    List<int> parse(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
      if (p != q) return p > q;
    }
    return false;
  }

  /// 앱 시작 시 호출: 새 버전이 있으면 알림 창을 띄운다.
  static Future<void> checkAndPrompt(BuildContext context) async {
    final found = await check();
    if (found == null || !context.mounted) return;
    final (version, notes, url) = found;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.system_update_rounded, color: AppColors.accent, size: 36),
        title: Text('새 버전 v$version'),
        content: SingleChildScrollView(
          child: Text(notes.isEmpty ? '새 버전이 나왔습니다.' : notes,
              style: const TextStyle(color: AppColors.muted, height: 1.5)),
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
        builder: (_) => _DownloadDialog(url: url, version: version),
      );
    }
  }
}

/// 내려받기 진행률을 보여주고, 다 받으면 설치 화면을 띄운다.
class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.url, required this.version});

  final String url;
  final String version;

  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    OtaUpdate().execute(widget.url, destinationFilename: 'BookScan-${widget.version}.apk').listen(
      (e) {
        if (!mounted) return;
        switch (e.status) {
          case OtaStatus.DOWNLOADING:
            setState(() => _progress = (double.tryParse(e.value ?? '') ?? 0) / 100);
          case OtaStatus.INSTALLING:
          case OtaStatus.INSTALLATION_DONE:
            Navigator.pop(context); // 시스템 설치 화면으로 넘어간다
          default:
            setState(() => _error = '업데이트 실패 (${e.status.name})${e.value == null ? '' : '\n${e.value}'}');
        }
      },
      onError: (e) {
        if (mounted) setState(() => _error = '업데이트 실패: $e');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_error == null ? '내려받는 중…' : '업데이트 실패'),
      content: _error != null
          ? Text(_error!)
          : Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: _progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 12),
              Text(_progress == null ? '준비 중' : '${(_progress! * 100).round()}%'),
            ]),
      actions: [
        if (_error != null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기')),
      ],
    );
  }
}
