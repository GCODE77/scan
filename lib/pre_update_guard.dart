// v0.30.0 첫 실행 보호: 저장 구조가 바뀌는 첫 실행 때 문서 폴더를 앱 안에 한 번 복사해 둔다.
// 순수한 부분은 docs_snapshot.dart. 여기는 화면과 남은 공간 확인.
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'backup_core.dart' show hasEnoughSpace;
import 'docs_snapshot.dart';
import 'theme.dart';

const _channel = MethodChannel('bookscan/backup');

String _mb(int b) => b >= 1024 * 1024 * 1024
    ? '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)}GB'
    : '${(b / 1024 / 1024).toStringAsFixed(1)}MB';

Future<int?> _freeSpace(String path) async {
  try {
    return (await _channel.invokeMethod<num>('freeSpace', {'path': path}))?.toInt();
  } catch (_) {
    return null;
  }
}

/// 첫 실행 보호의 결과.
enum GuardResult { skipped, copied, noSpace, failed }

class PreUpdateGuard {
  /// 첫 실행이면 문서 폴더를 복사한다. 표시 파일이 있으면 아무것도 하지 않는다.
  /// 화면에 알릴 일은 [context]를 통해 직접 알린다. 복사가 끝나야 돌아오므로 이 뒤에 문서를 저장해도 안전하다.
  static Future<GuardResult> run(BuildContext context) async {
    try {
      final base = (await getApplicationDocumentsDirectory()).path;
      if (markerExists(base)) return GuardResult.skipped;
      final docs = Directory('$base/docs');
      // 문서가 아직 없는 새 설치: 지킬 것이 없다
      if (!hasAnyDoc(docs)) {
        writeMarker(base, 'nodocs');
        return GuardResult.skipped;
      }
      final size = dirSize(docs);
      final free = await _freeSpace(base);
      if (free == null || !hasEnoughSpace(free, size)) {
        writeMarker(base, 'nospace');
        if (context.mounted) {
          await _alert(
              context,
              '업데이트 전 사본을 만들지 못했어요',
              '남은 저장 공간이 부족해서 문서 사본을 만들지 못했습니다'
                  '${free == null ? '' : ' (문서 ${_mb(size)}, 남은 공간 ${_mb(free)})'}.\n\n'
                  '문서를 잃지 않도록 백업 파일을 먼저 만드세요. '
                  '(오른쪽 위 메뉴의 백업 만들기)');
        }
        return GuardResult.noSpace;
      }
      if (!context.mounted) return GuardResult.skipped; // 표시를 남기지 않았으니 다음 실행 때 다시 한다
      final close = _showWorking(context);
      bool ok;
      try {
        ok = await Isolate.run(() => makeSnapshot(base));
      } catch (_) {
        ok = false;
      }
      close();
      if (ok) {
        writeMarker(base, 'copied');
        return GuardResult.copied;
      }
      // 실패: 표시를 남기지 않아 다음 실행 때 다시 시도한다
      if (context.mounted) {
        await _alert(context, '업데이트 전 사본을 만들지 못했어요',
            '문서를 복사하는 중에 문제가 생겼습니다. 앱은 그대로 쓸 수 있지만, 안전을 위해 백업 파일을 만들어 두세요.');
      }
      return GuardResult.failed;
    } catch (_) {
      return GuardResult.failed;
    }
  }

  /// 숨은 메뉴: 업데이트 전 문서로 되돌리기. 되돌렸으면 true.
  static Future<bool> restoreFlow(BuildContext context) async {
    final base = (await getApplicationDocumentsDirectory()).path;
    if (!context.mounted) return false;
    if (!snapshotExists(base)) {
      await _alert(context, '되돌릴 사본이 없어요', '업데이트 전에 만들어 둔 문서 사본을 찾지 못했습니다.');
      return false;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.history_rounded, color: AppColors.accent, size: 36),
        title: const Text('업데이트 전 문서로 되돌릴까요?'),
        content: const Text(
          '지금 보관함의 문서가 모두 업데이트 직전 상태로 바뀝니다. '
          '그 뒤에 새로 만들거나 고친 내용은 사라지고, 되돌릴 수 없습니다.\n\n'
          '정말 되돌릴까요?',
          style: TextStyle(height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('되돌리기')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    final done = restoreSnapshot(base);
    if (!context.mounted) return done;
    await _alert(
        context,
        done ? '되돌렸어요' : '되돌리지 못했어요',
        done
            ? '문서를 업데이트 전 상태로 되돌렸습니다.'
            : '문서를 되돌리는 중에 문제가 생겼습니다. 지금 문서는 그대로 두었습니다.');
    return done;
  }
}

/// 진행 창. 돌려준 함수를 부르면 닫힌다.
VoidCallback _showWorking(BuildContext context) {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (d) => const PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('문서를 안전하게 복사하는 중'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(),
          SizedBox(height: 14),
          Text('업데이트 전 문서를 한 번 복사해 둡니다. 처음 한 번만 하며, 끝날 때까지 앱을 닫지 마세요.',
              style: TextStyle(height: 1.5)),
        ]),
      ),
    ),
  );
  var closed = false;
  return () {
    if (closed) return;
    closed = true;
    if (nav.mounted) nav.pop();
  };
}

Future<void> _alert(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body, style: const TextStyle(height: 1.5)),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('확인'))],
      ),
    );
