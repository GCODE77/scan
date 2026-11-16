// 백업·복원 화면 쪽. 순수한 부분은 backup_core.dart, 저장·열기 창은 MainActivity.kt 의 'bookscan/backup' 채널.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'backup_core.dart';
import 'ocr.dart' show newId;
import 'storage.dart';
import 'theme.dart';
import 'updater.dart';

const _channel = MethodChannel('bookscan/backup');

String _mb(int b) => b >= 1024 * 1024 * 1024
    ? '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB'
    : '${(b / 1024 / 1024).toStringAsFixed(1)}MB';

Future<String> _docsRoot() async => '${(await getApplicationDocumentsDirectory()).path}/docs';

/// 남은 공간(바이트). 알 수 없으면 null.
Future<int?> _freeSpace(String path) async {
  try {
    return (await _channel.invokeMethod<num>('freeSpace', {'path': path}))?.toInt();
  } catch (_) {
    return null;
  }
}

/// 지난번에 남은 임시 파일 정리
void _cleanStale(Directory tmp) {
  try {
    for (final e in tmp.listSync()) {
      final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is File && (n == 'import.zip' || (n.startsWith('bookscan_backup_') && n.endsWith('.zip')))) {
        e.deleteSync();
      }
    }
  } catch (_) {}
}

Future<void> _alert(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(height: 1.5)),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('확인'))],
      ),
    );

/// 진행 중 창. 돌려준 함수를 부르면 닫힌다.
VoidCallback _showProgress(BuildContext context, String title, ValueNotifier<(int, int)?> progress) {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (d) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<(int, int)?>(
          valueListenable: progress,
          builder: (_, p, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: p == null || p.$2 == 0 ? null : p.$1 / p.$2),
            const SizedBox(height: 14),
            Text(p == null ? '준비하는 중…' : '문서 ${p.$1}/${p.$2}'),
            const SizedBox(height: 6),
            const Text('끝날 때까지 앱을 닫지 마세요.', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          ]),
        ),
      ),
    ),
  );
  var closed = false;
  return () {
    if (closed) return;
    closed = true;
    nav.pop();
  };
}

// ── 백그라운드(Isolate)에서 ZIP 만들기·풀기. 화면이 멈추지 않게 한다. ──

class _ZipJob {
  _ZipJob(this.port, this.zip, this.docs, this.app);
  final SendPort port;
  final String zip;
  final List<BackupDoc> docs;
  final String app;
}

void _zipEntry(_ZipJob j) {
  try {
    writeBackupZip(
        zipPath: j.zip, docs: j.docs, appVersion: j.app, onDoc: (i, n) => j.port.send([i, n]));
    j.port.send('done');
  } catch (_) {
    j.port.send('error');
  }
}

class _ImportJob {
  _ImportJob(this.port, this.zip, this.root, this.existing, this.policy);
  final SendPort port;
  final String zip;
  final String root;
  final Set<String> existing;
  final DuplicatePolicy policy;
}

void _importEntry(_ImportJob j) {
  try {
    final r = importBackup(
        zipPath: j.zip,
        docsRoot: j.root,
        existingIds: j.existing,
        policy: j.policy,
        makeId: newId,
        onDoc: (i, n) => j.port.send([i, n]));
    j.port.send({'imported': r.imported, 'copied': r.copied, 'skipped': r.skipped, 'failed': r.failed});
  } catch (_) {
    j.port.send('error');
  }
}

/// Isolate 를 띄우고 진행 알림은 [onProgress]로, 마지막 메시지(문자열 또는 맵)를 돌려준다. 죽으면 'error'.
Future<Object> _run<J>(void Function(J) entry, J Function(SendPort) makeJob, void Function(int, int) onProgress) async {
  final rp = ReceivePort();
  final done = Completer<Object>();
  final exit = ReceivePort();
  rp.listen((m) {
    if (m is List) {
      onProgress(m[0] as int, m[1] as int);
    } else if (!done.isCompleted) {
      done.complete(m as Object);
    }
  });
  exit.listen((_) {
    if (!done.isCompleted) done.complete('error');
  });
  await Isolate.spawn(entry, makeJob(rp.sendPort), onExit: exit.sendPort);
  final r = await done.future;
  rp.close();
  exit.close();
  return r;
}

class Backup {
  /// 보관함의 [docs] 를 백업 ZIP 으로 묶어 저장 위치를 고르게 한다.
  static Future<void> create(BuildContext context, List<ScanDoc> docs) async {
    if (docs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('백업할 문서가 없습니다')));
      return;
    }
    final root = await _docsRoot();
    final tmp = await getTemporaryDirectory();
    _cleanStale(tmp);
    final plan = planBackup(root, docs.map((d) => d.id));
    if (plan.isEmpty) {
      if (context.mounted) await _alert(context, '백업할 문서가 없습니다', '문서 파일을 찾지 못했습니다.');
      return;
    }
    final size = estimateBackupSize(plan);
    final free = await _freeSpace(tmp.path);
    if (!context.mounted) return;
    if (free != null && !hasEnoughSpace(free, size)) {
      await _alert(
          context,
          '저장 공간이 부족합니다',
          '백업 파일을 만들려면 약 ${_mb((size * 1.1).ceil())}가 비어 있어야 합니다. '
              '지금은 ${_mb(free)}만 남았습니다.\n\n'
              '쓰지 않는 문서를 지우거나, 저장 공간 메뉴에서 원본 사진을 줄인 뒤 다시 해 보세요.');
      return;
    }
    final app = await Updater.currentVersion();
    final stamp = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name =
        'BookScan_backup_${stamp.year}${two(stamp.month)}${two(stamp.day)}_${two(stamp.hour)}${two(stamp.minute)}.zip';
    final zip = '${tmp.path}/bookscan_backup_${stamp.millisecondsSinceEpoch}.zip';
    if (!context.mounted) return;

    final progress = ValueNotifier<(int, int)?>(null);
    final close = _showProgress(context, '백업 파일 만드는 중', progress);
    Object res;
    try {
      res = await _run(_zipEntry, (port) => _ZipJob(port, zip, plan, app), (i, n) {
        progress.value = (i, n);
      });
    } catch (_) {
      res = 'error';
    }
    close();
    progress.dispose();
    if (res != 'done') {
      _delete(zip);
      if (context.mounted) {
        await _alert(context, '백업 파일을 만들지 못했습니다', '저장 공간이 부족하거나 문서 파일을 읽지 못했습니다. 공간을 확보한 뒤 다시 해 보세요.');
      }
      return;
    }
    if (!context.mounted) {
      _delete(zip);
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (d) => _BackupDoneDialog(path: zip, name: name, docCount: plan.length, size: File(zip).lengthSync()),
      );
    } finally {
      _delete(zip);
    }
  }

  /// 백업 ZIP 을 골라 문서를 보관함으로 가져온다. 끝나면 [onDone].
  static Future<void> restore(BuildContext context, Future<void> Function() onDone) async {
    final tmp = await getTemporaryDirectory();
    _cleanStale(tmp);
    final root = await _docsRoot();
    if (!context.mounted) return;

    // 1) 파일 고르고 임시 폴더로 복사 (네이티브가 조금씩 복사)
    final spinner = ValueNotifier<(int, int)?>(null);
    final closeSpinner = _showProgress(context, '백업 파일 읽는 중', spinner);
    Map<Object?, Object?>? pick;
    try {
      pick = await _channel.invokeMethod<Map<Object?, Object?>>('openFile', {'destDir': tmp.path});
    } catch (_) {
      pick = {'status': 'error', 'message': '파일 선택 창을 열지 못했습니다.'};
    }
    closeSpinner();
    spinner.dispose();
    final status = pick?['status'];
    if (status == 'cancel' || pick == null) return;
    if (status != 'ok') {
      if (context.mounted) await _alert(context, '파일을 가져오지 못했습니다', '${pick['message'] ?? '다시 해 보세요.'}');
      return;
    }
    final zip = pick['path'] as String;
    try {
      if (!context.mounted) return;
      // 2) 공간 확인 (풀면 ZIP 크기만큼 더 쓴다)
      final size = File(zip).lengthSync();
      final free = await _freeSpace(root);
      if (!context.mounted) return;
      if (free != null && !hasEnoughSpace(free, size)) {
        await _alert(
            context,
            '저장 공간이 부족합니다',
            '이 백업(${_mb(size)})을 풀려면 약 ${_mb((size * 1.1).ceil())}가 더 필요합니다. '
                '지금은 ${_mb(free)}만 남았습니다. 공간을 확보한 뒤 다시 해 보세요.');
        return;
      }
      // 3) 형식 번호와 문서 목록 확인
      BackupInfo info;
      try {
        info = inspectBackup(zip);
      } on BackupException catch (e) {
        await _alert(context, '가져올 수 없는 파일입니다', e.message);
        return;
      } catch (_) {
        await _alert(context, '가져올 수 없는 파일입니다', '백업 파일이 아니거나 손상된 파일입니다.');
        return;
      }
      if (info.docs.isEmpty) {
        await _alert(context, '가져올 문서가 없습니다', '이 백업 파일에는 문서가 들어 있지 않습니다.');
        return;
      }
      // 4) 이미 있는 문서
      final existing = <String>{
        for (final e in Directory(root).listSync())
          if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last
      };
      final dups = info.docs.where((d) => existing.contains(d.id)).toList();
      var policy = DuplicatePolicy.skip;
      if (dups.isNotEmpty) {
        final choice = await showDialog<DuplicatePolicy>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('이미 있는 문서가 ${dups.length}개 있어요'),
            content: Text(
              '백업 ${info.docs.length}개 중 ${dups.length}개가 보관함에 같은 문서로 이미 있습니다.\n\n'
              '건너뛰면 지금 문서를 그대로 둡니다. 복사본으로 가져오면 \'(복사본)\'이 붙은 새 문서로 따로 들어옵니다.',
              style: const TextStyle(height: 1.5),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('취소')),
              OutlinedButton(onPressed: () => Navigator.pop(d, DuplicatePolicy.skip), child: const Text('건너뛰기')),
              FilledButton(onPressed: () => Navigator.pop(d, DuplicatePolicy.copy), child: const Text('복사본으로')),
            ],
          ),
        );
        if (choice == null) return;
        policy = choice;
      }
      if (!context.mounted) return;
      // 5) 풀기
      final progress = ValueNotifier<(int, int)?>(null);
      final close = _showProgress(context, '문서 가져오는 중', progress);
      Object res;
      try {
        res = await _run(_importEntry, (port) => _ImportJob(port, zip, root, existing, policy),
            (i, n) => progress.value = (i, n));
      } catch (_) {
        res = 'error';
      }
      close();
      progress.dispose();
      await onDone();
      if (!context.mounted) return;
      if (res is! Map) {
        await _alert(context, '가져오기를 마치지 못했습니다', '저장 공간이 부족하거나 파일이 손상됐을 수 있습니다. 이미 들어온 문서는 보관함에 있습니다.');
        return;
      }
      final failed = (res['failed'] as List).length;
      final lines = <String>[
        '${(res['imported'] as int) + (res['copied'] as int)}개 가져왔습니다.',
        if ((res['copied'] as int) > 0) '그중 ${res['copied']}개는 복사본으로 들어왔습니다.',
        if ((res['skipped'] as int) > 0) '${res['skipped']}개는 이미 있어서 건너뛰었습니다.',
        if (failed > 0) '$failed개는 가져오지 못했습니다(파일이 손상됐을 수 있습니다).',
        if (info.ignoredEntries > 0) '읽을 수 없는 항목 ${info.ignoredEntries}개는 무시했습니다.',
      ];
      await _alert(context, failed > 0 ? '일부만 가져왔어요' : '가져오기 끝', lines.join('\n'));
    } finally {
      _delete(zip);
    }
  }

  static void _delete(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// 백업 파일이 준비된 뒤: 저장 위치 고르기(주) / 공유로 보내기(보조) / 닫기(임시 파일 삭제).
class _BackupDoneDialog extends StatefulWidget {
  const _BackupDoneDialog({required this.path, required this.name, required this.docCount, required this.size});
  final String path;
  final String name;
  final int docCount;
  final int size;

  @override
  State<_BackupDoneDialog> createState() => _BackupDoneDialogState();
}

class _BackupDoneDialogState extends State<_BackupDoneDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    Map<Object?, Object?>? r;
    try {
      r = await _channel.invokeMethod<Map<Object?, Object?>>('saveFile', {'path': widget.path, 'name': widget.name});
    } catch (_) {
      r = {'status': 'error', 'message': '저장 창을 열지 못했습니다.'};
    }
    if (!mounted) return;
    final status = r?['status'];
    if (status == 'saved') {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('백업 파일을 저장했습니다')));
      return;
    }
    setState(() {
      _busy = false;
      if (status == 'error') _error = '${r?['message'] ?? '저장하지 못했습니다.'}';
    });
  }

  Future<void> _share() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(widget.path, mimeType: 'application/zip', name: widget.name)]));
    } catch (_) {
      if (mounted) _error = '공유 창을 열지 못했습니다.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        icon: const Icon(Icons.inventory_2_rounded, color: AppColors.accent, size: 36),
        title: const Text('백업 파일이 준비됐어요'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('문서 ${widget.docCount}개 · ${_mb(widget.size)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            '저장할 위치를 고르면 그 위치에 파일이 만들어집니다. 안전한 곳(드라이브, 컴퓨터 등)에 꼭 한 벌 두세요. '
            '창을 닫으면 지금 만든 임시 파일은 지워집니다.',
            style: TextStyle(height: 1.5, fontSize: 13),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: Colors.redAccent, height: 1.4)),
          ],
          if (_busy) ...[const SizedBox(height: 14), const LinearProgressIndicator()],
        ]),
        actionsOverflowDirection: VerticalDirection.down,
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('닫기')),
          OutlinedButton.icon(
              onPressed: _busy ? null : _share, icon: const Icon(Icons.ios_share_rounded), label: const Text('공유로 보내기')),
          FilledButton.icon(
              onPressed: _busy ? null : _save, icon: const Icon(Icons.save_alt_rounded), label: const Text('저장 위치 고르기')),
        ],
      ),
    );
  }
}
