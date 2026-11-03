import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_screen.dart';
import 'crop_screen.dart';
import 'gallery_import.dart';
import 'ocr.dart';
import 'rect_crop_screen.dart';
import 'scanner.dart';
import 'signature.dart';
import 'theme.dart';

/// 촬영 후 편집 화면: 필터 고르기, 회전, 자르기, 다시 찍기, 텍스트 추출.
/// [pages] 목록을 직접 고친다.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.pages, this.initial = 0});

  final List<ScanPage> pages;
  final int initial;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final _pager = PageController(initialPage: widget.initial);
  late int _index = widget.initial;
  bool _busy = false;
  bool _compare = false;

  /// 지금 페이지가 확대돼 있는지 (확대 중에는 옆으로 밀어도 페이지가 넘어가지 않게)
  bool _zoomed = false;

  /// 필터 미리보기 썸네일 캐시 (편 이미지별)
  final _thumbs = Expando<Future<Map<ScanMode, Uint8List>>>();

  List<ScanPage> get _pages => widget.pages;
  ScanPage get _page => _pages[_index];

  // ── 되돌리기 ──
  /// 바꾸기 직전 상태들 (최근 20개)
  final List<_Snapshot> _history = [];

  void _push() {
    _history.add(_Snapshot.of(_pages, _index));
    if (_history.length > 20) _history.removeAt(0);
  }

  void _undo() {
    if (_history.isEmpty || _busy) return;
    HapticFeedback.selectionClick();
    final snap = _history.removeLast();
    setState(() {
      snap.restore(_pages);
      _index = snap.index.clamp(0, _pages.length - 1);
    });
    _pager.jumpToPage(_index);
  }

  Future<void> _work(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<ScanMode, Uint8List>> _thumbsFor(ScanPage p) => _thumbs[p.flat] ??= _makeThumbs(p.flat);

  static Future<Map<ScanMode, Uint8List>> _makeThumbs(Uint8List flat) async => {
        for (final m in ScanMode.values) m: await compute(renderPage, (flat, m, 0, 240, 1.0)),
      };

  void _setFilter(ScanMode m, {bool all = false}) => _work(() async {
        _push();
        for (final p in List.of(all ? _pages : [_page])) {
          if (!_pages.contains(p) || p.mode == m) continue;
          p.mode = m;
          p.strength = 1; // 새 필터는 최대 강도부터
          await p.render();
        }
      });

  /// 90도 회전 (-1: 왼쪽, 1: 오른쪽)
  void _rotate(int dir) => _work(() async {
        _push();
        HapticFeedback.selectionClick();
        _page.quarterTurns += dir;
        // 얹은 서명도 페이지와 함께 돈다
        for (final st in _page.stamps) {
          final r = st.rect;
          st.rect = dir > 0
              ? Rect.fromLTWH(1 - r.bottom, r.left, r.height, r.width)
              : Rect.fromLTWH(r.top, 1 - r.right, r.height, r.width);
          st.turns += dir;
        }
        await _page.render();
      });

  /// 자동 정리: 손가락 지우기 + 그림자·빛 반사 고르게. 다시 누르면 되돌린다.
  Future<void> _clean() async {
    final p = _page;
    if (p.cleaned) {
      if (p.rawFlat == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('되돌리려면 위쪽 되돌리기 버튼을 누르거나 "윤곽 수정" → "이대로 펴기"로 다시 펴 주세요')));
        return;
      }
      await _work(() async {
        _push();
        p.flat = p.rawFlat!;
        p.rawFlat = null;
        p.cleaned = false;
        await p.render();
      });
      return;
    }
    await _work(() async {
      _push();
      p.rawFlat = p.flat;
      p.flat = await compute(cleanPage, p.flat);
      p.cleaned = true;
      await p.render();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('손가락·그림자·빛 반사를 정리했어요 (다시 누르면 되돌림)')));
    }
  }

  /// 빛 반사 제거 / 기울기 보정처럼 편 이미지를 바로 고치는 작업. [all]이면 모든 페이지.
  /// [job]이 (새 이미지, 변화량)을 주면 적용하고, 변화량이 0이면 건너뛴다. 고친 페이지 수를 돌려준다.
  Future<int> _fixFlat(Future<(Uint8List, double)> Function(Uint8List) job,
      {required bool all, bool rotates = false}) async {
    var changed = 0;
    await _work(() async {
      _push();
      for (final p in List.of(all ? _pages : [_page])) {
        if (!_pages.contains(p)) continue; // 작업 중에 지워진 페이지
        final (bytes, amount) = await job(p.flat);
        if (amount == 0) continue;
        p.flat = bytes;
        p.rawFlat = null; // 정리 취소용 원본은 이 보정과 어긋나므로 버린다 (되돌리기 버튼으로 취소)
        // 이미지를 돌렸으면 배경 제거 마스크도 같은 각도로
        if (rotates && p.cutMask != null) p.cutMask = await compute(rotateMask, (p.cutMask!, amount));
        await p.render();
        changed++;
      }
      if (changed == 0) _history.removeLast(); // 바뀐 게 없으면 되돌리기 기록도 남기지 않는다
    });
    return changed;
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _glare({bool all = false}) async {
    final n = await _fixFlat((f) => compute(glarePage, f), all: all);
    _toast(n == 0 ? '지울 빛 반사를 찾지 못했어요' : '빛 반사를 지웠어요${all ? ' ($n페이지)' : ''} · 되돌리기로 취소');
  }

  Future<void> _deskew({bool all = false}) async {
    final n = await _fixFlat((f) => compute(deskewPage, f), all: all, rotates: true);
    _toast(n == 0 ? '이미 반듯하거나 기울기를 알 수 없어요' : '기울기를 바로잡았어요${all ? ' ($n페이지)' : ''} · 되돌리기로 취소');
  }

  /// 보이는 화면(회전 반영)에서 고른 영역(0~1)을 회전 전 편 이미지의 영역으로 바꾼다.
  static Rect _toFlatRect(Rect v, int turns) => switch (turns % 4) {
        1 => Rect.fromLTRB(v.top, 1 - v.right, v.bottom, 1 - v.left),
        2 => Rect.fromLTRB(1 - v.right, 1 - v.bottom, 1 - v.left, 1 - v.top),
        3 => Rect.fromLTRB(1 - v.bottom, v.left, 1 - v.top, v.right),
        _ => v,
      };

  /// 사각형 영역 자르기: 쓰고 싶은 부분만 남기거나, 복사본 페이지로 따로 뽑는다.
  Future<void> _areaCrop() async {
    final p = _page;
    final res = await Navigator.push<(Rect, bool)>(
        context, MaterialPageRoute(builder: (_) => RectCropScreen(image: p.jpg)));
    if (res == null || !mounted) return;
    final (view, asCopy) = res;
    final r = _toFlatRect(view, p.quarterTurns);
    final box = [r.left, r.top, r.right, r.bottom];
    var note = '';
    await _work(() async {
      _push();
      final flat = await compute(cropNorm, (p.flat, box, false));
      final mask = p.cutMask == null ? null : await compute(cropNorm, (p.cutMask!, box, true));
      if (asCopy) {
        // 자른 부분이 곧 새 페이지의 원본이 된다 (윤곽 수정을 다시 해도 안전)
        final codec = await ui.instantiateImageCodec(flat);
        final im = (await codec.getNextFrame()).image;
        final w = im.width.toDouble(), h = im.height.toDouble();
        final det = Detection(flat, im.width, im.height,
            PageShape.quad([Offset.zero, Offset(w, 0), Offset(w, h), Offset(0, h)], false), true);
        final copy = ScanPage(det: det, shape: det.shape, part: 0, flat: flat)
          ..mode = p.mode
          ..strength = p.strength
          ..quarterTurns = p.quarterTurns
          ..cutMask = mask;
        await copy.render();
        final at = _index + 1;
        setState(() {
          _pages.insert(at, copy);
          _index = at;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pager.hasClients) _pager.jumpToPage(at);
        });
        note = '잘라낸 부분을 새 페이지로 추가했어요';
      } else {
        p.flat = flat;
        p.cutMask = mask;
        if (p.rawFlat != null) p.rawFlat = await compute(cropNorm, (p.rawFlat!, box, false));
        final hadStamps = p.stamps.isNotEmpty;
        p.stamps.clear(); // 서명 위치는 원래 페이지 기준이라 자르면 어긋난다
        await p.render();
        note = hadStamps ? '잘랐어요 (서명은 위치가 어긋나 지웠어요)' : '잘랐어요';
      }
    });
    _toast('$note · 되돌리기로 취소');
  }

  /// ML Kit 배경 인식. 처음에는 구글 플레이 서비스가 모델을 내려받는 중일 수 있어, 그동안 기다리며 다시 시도한다.
  /// 대상 확신도(0~1)를 돌려주고, 쓸 수 없으면 null.
  Future<List<double>?> _segment(SubjectSegmenter seg, String path) async {
    var told = false;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        return (await seg.processImage(InputImage.fromFilePath(path))).foregroundConfidenceMask;
      } on PlatformException catch (e) {
        final msg = '${e.message}'.toLowerCase();
        debugPrint('배경 인식 오류: ${e.code} / ${e.message}');
        // 모델을 내려받는 중이면 잠시 뒤 다시, 그 밖의 오류는 대체 방식으로
        if (!(msg.contains('download') || msg.contains('waiting'))) return null;
        if (!told) {
          told = true;
          _toast('배경 인식 모델을 내려받는 중이에요 (처음 한 번만, 잠시만요)');
        }
        await Future.delayed(const Duration(seconds: 4));
      } catch (e) {
        debugPrint('배경 인식 실패: $e');
        return null;
      }
    }
    return null;
  }

  /// 배경 제거(기기 안에서 처리). 이미 제거한 페이지를 누르면 되돌린다. 길게 누르면 모든 페이지.
  /// AI(ML Kit)를 쓸 수 없으면 기본 방식(GrabCut)으로 대신한다.
  Future<void> _removeBg({bool all = false}) async {
    if (!all && _page.cutMask != null) {
      await _work(() async {
        _push();
        _page.cutMask = null;
        await _page.render();
      });
      _toast('배경을 되돌렸어요');
      return;
    }
    final targets = all ? _pages.where((p) => p.cutMask == null).toList() : [_page];
    if (targets.isEmpty) return;
    var done = 0, fallback = 0;
    await _work(() async {
      _push();
      final dir = await getTemporaryDirectory();
      final seg = SubjectSegmenter(
          options: SubjectSegmenterOptions(
              enableForegroundBitmap: false,
              enableForegroundConfidenceMask: true,
              enableMultipleSubjects:
                  SubjectResultOptions(enableConfidenceMask: false, enableSubjectBitmap: false)));
      var aiOk = true; // 한 번 쓸 수 없으면 이번 작업에서는 더 시도하지 않는다
      try {
        for (final p in targets) {
          Uint8List? mask;
          if (aiOk) {
            final (small, w, h, fw, fh) = await compute(prepSegment, p.flat);
            final f = await File('${dir.path}/seg_${p.id}.jpg').writeAsBytes(small);
            final conf = await _segment(seg, f.path);
            f.delete().ignore();
            if (conf == null || conf.length != w * h) {
              aiOk = false;
            } else if (conf.where((v) => v > 0.5).length >= conf.length * 0.03) {
              mask = await compute(buildCutMask, (conf, w, h, fw, fh));
            } // 대상을 못 찾았으면(3% 미만) 이 페이지만 기본 방식으로
          }
          if (mask == null) {
            final gc = await compute(grabCutMask, p.flat);
            if (gc.isEmpty) continue; // 대상을 못 찾았다: 이 페이지는 그대로 둔다 (흰 페이지가 되지 않게)
            mask = gc;
            fallback++;
          }
          p.cutMask = mask;
          await p.render();
          done++;
        }
      } catch (e) {
        debugPrint('배경 제거 실패: $e');
      } finally {
        try {
          await seg.close();
        } catch (_) {}
      }
      if (done == 0 && _history.isNotEmpty) _history.removeLast();
    });
    if (done == 0) {
      _toast('배경을 지우지 못했어요. 대상이 사진 가운데 크게 보이게 윤곽을 맞춘 뒤 다시 해 보세요');
    } else {
      _toast('${all ? '배경을 지웠어요 ($done페이지)' : '배경을 지웠어요'}'
          '${fallback > 0 ? ' · AI 모델을 쓰지 못해 기본 방식으로 처리했어요(단순한 배경에서 잘 돼요)' : ''}'
          ' · PNG로 저장하면 투명 배경 · 되돌리기로 취소');
    }
  }

  /// 서명 넣기 (이미 있으면 추가/모두 지우기 선택)
  Future<void> _sign() async {
    final p = _page;
    if (p.stamps.isNotEmpty) {
      final act = await showModalBottomSheet<String>(
        context: context,
        builder: (s) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
                leading: const Icon(Icons.add_rounded),
                title: const Text('서명 추가'),
                onTap: () => Navigator.pop(s, 'add')),
            ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                title: Text('이 페이지 서명 모두 지우기 (${p.stamps.length}개)',
                    style: const TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.pop(s, 'clear')),
          ]),
        ),
      );
      if (act == null) return;
      if (act == 'clear') {
        await _work(() async {
          _push();
          p.stamps.clear();
          await p.render();
        });
        return;
      }
    }
    if (!mounted) return;
    final png = await makeSignature(context);
    if (png == null || !mounted) return;
    final codec = await ui.instantiateImageCodec(p.jpg);
    final img = (await codec.getNextFrame()).image;
    if (!mounted) return;
    final rect = await placeSignature(
        context, p.jpg, Size(img.width.toDouble(), img.height.toDouble()), png);
    if (rect == null) return;
    await _work(() async {
      _push();
      p.stamps.add(Stamp(png, rect));
      await p.render();
    });
  }

  /// 슬라이더를 움직이는 동안 보여 줄 값 (손을 떼면 적용)
  double? _strengthDrag;

  void _setStrength(double v) => _work(() async {
        _push();
        _page.strength = v;
        await _page.render();
        _strengthDrag = null;
      });

  /// 같은 사진에서 나온 페이지들(양면이면 2장)의 위치
  List<int> _group(ScanPage p) =>
      [for (var i = 0; i < _pages.length; i++) if (identical(_pages[i].det, p.det)) i];

  /// 같은 사진의 페이지들을 새 페이지들로 바꾼다 (필터·회전은 유지)
  Future<void> _replaceGroup(ScanPage old, List<ScanPage> fresh) async {
    final idx = _group(old);
    for (final p in fresh) {
      p.mode = old.mode;
      p.quarterTurns = old.quarterTurns;
      await p.render();
    }
    setState(() {
      for (final i in idx.reversed) {
        _pages.removeAt(i);
      }
      _pages.insertAll(idx.first, fresh);
      _index = idx.first + (old.part).clamp(0, fresh.length - 1);
    });
    _pager.jumpToPage(_index);
  }

  Future<void> _crop() async {
    final p = _page;
    final shape = await Navigator.push<PageShape>(context,
        MaterialPageRoute(builder: (_) => CropScreen(detection: p.det, initial: p.shape)));
    if (shape == null) return;
    await _work(() async {
      _push();
      final flats = await compute(warpFlat, (p.det.jpg, shape));
      await _replaceGroup(p, [
        for (var i = 0; i < flats.length; i++) ScanPage(det: p.det, shape: shape, part: i, flat: flats[i]),
      ]);
    });
  }

  Future<void> _retake() async {
    final p = _page;
    final fresh = await Navigator.push<List<ScanPage>>(
        context, MaterialPageRoute(builder: (_) => const CameraScreen()));
    if (fresh == null || fresh.isEmpty) return;
    _push();
    await _work(() => _replaceGroup(p, fresh));
  }

  /// 페이지 추가: 카메라로 찍거나 갤러리에서 가져와 지금 페이지 뒤에 끼워 넣는다.
  Future<void> _add() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('카메라로 찍기'),
              onTap: () => Navigator.pop(s, 'camera')),
          ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('갤러리에서 가져오기'),
              onTap: () => Navigator.pop(s, 'gallery')),
        ]),
      ),
    );
    if (how == null || !mounted) return;
    final fresh = how == 'camera'
        ? await Navigator.push<List<ScanPage>>(
            context, MaterialPageRoute(builder: (_) => const CameraScreen()))
        : await pickAndScan(context);
    if (fresh == null || fresh.isEmpty || !mounted) return;
    _push();
    final at = _index + 1;
    setState(() {
      _pages.insertAll(at, fresh);
      _index = at;
    });
    // 새 페이지가 그려진 뒤에 그 페이지로 이동
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pager.hasClients) _pager.jumpToPage(at);
    });
    _toast('${fresh.length}페이지를 추가했어요 · 되돌리기로 취소');
  }

  void _delete() {
    if (_busy) return; // 다른 작업이 이 페이지들을 쓰는 중
    if (_pages.length > 1) _push(); // 마지막 페이지를 지우면 화면이 닫힌다
    setState(() {
      _pages.removeAt(_index);
      if (_index >= _pages.length) _index = _pages.length - 1;
    });
    if (_pages.isEmpty) Navigator.pop(context);
  }

  Future<void> _extractText() async {
    final p = _page;
    if (p.ocr == null) {
      await _work(() async => p.ocr = await Ocr.recognize(p));
    }
    if (!mounted) return;
    final text = p.ocr!.text;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, scroll) => Column(children: [
          ListTile(
            title: const Text('텍스트 추출 (한국어·영어)'),
            trailing: TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('복사'),
              onPressed: text.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: text));
                      Navigator.pop(sheet);
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('복사했습니다')));
                    },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(20),
              child: SelectableText(text.isEmpty ? '인식된 글자가 없습니다' : text,
                  style: const TextStyle(fontSize: 16, height: 1.6)),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) return const SizedBox();
    const bg = AppColors.bg;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        title: Text('편집 · ${_index + 1}/${_pages.length}'),
        actions: [
          IconButton(
            tooltip: '되돌리기',
            icon: const Icon(Icons.undo_rounded),
            onPressed: _history.isEmpty || _busy ? null : _undo,
          ),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            PageView.builder(
              controller: _pager,
              itemCount: _pages.length,
              physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
              onPageChanged: (i) => setState(() {
                _index = i;
                _zoomed = false;
              }),
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Stack(children: [
                  // 두 손가락으로 확대·이동, 두 번 누르면 확대/원래대로
                  Positioned.fill(
                    child: _ZoomPage(
                      key: ObjectKey(_pages[i]),
                      image: _compare && i == _index ? _pages[i].flat : _pages[i].jpg,
                      onZoom: (z) {
                        if (mounted && i == _index && z != _zoomed) setState(() => _zoomed = z);
                      },
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Material(
                      color: Colors.black45,
                      shape: const CircleBorder(),
                      child: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.white),
                        onPressed: _delete,
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            // 인식된 영역: 원본 사진 위 윤곽선. 누르면 바로 수정
            Positioned(
              left: 12,
              bottom: 8,
              child: _OutlinePreview(page: _page, onTap: _busy ? null : _crop),
            ),
            if (_busy) const Center(child: CircularProgressIndicator()),
          ]),
        ),
        // 페이지 번호 + 비교 (누르고 있는 동안 원본 보기)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.chevron_left, color: Colors.white),
              onPressed: _index == 0
                  ? null
                  : () => _pager.previousPage(
                      duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            ),
            Text('${_index + 1}/${_pages.length}', style: const TextStyle(color: Colors.white)),
            IconButton(
              icon: const Icon(Icons.chevron_right, color: Colors.white),
              onPressed: _index == _pages.length - 1
                  ? null
                  : () => _pager.nextPage(
                      duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
            ),
            const Spacer(),
            GestureDetector(
              onTapDown: (_) => setState(() => _compare = true),
              onTapUp: (_) => setState(() => _compare = false),
              onTapCancel: () => setState(() => _compare = false),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                    color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                child: const Row(children: [
                  Icon(Icons.compare, color: Colors.white, size: 18),
                  SizedBox(width: 6),
                  Text('비교', style: TextStyle(color: Colors.white)),
                ]),
              ),
            ),
          ]),
        ),
        // 필터 강도 (원본이 아닐 때만)
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          child: _page.mode == ScanMode.original
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 16, 0),
                  child: Row(children: [
                    Text('${scanModeLabels[_page.mode]} 강도',
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _strengthDrag ?? _page.strength,
                        divisions: 20,
                        onChanged: _busy ? null : (v) => setState(() => _strengthDrag = v),
                        onChangeEnd: _busy ? null : _setStrength,
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('${((_strengthDrag ?? _page.strength) * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
                  ]),
                ),
        ),
        // 필터 줄
        SizedBox(
          height: 104,
          child: FutureBuilder(
            future: _thumbsFor(_page),
            builder: (context, snap) => ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final m in ScanMode.values)
                  GestureDetector(
                    onTap: _busy
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            _setFilter(m);
                          },
                    onLongPress: _busy ? null : () => _filterAllDialog(m),
                    child: Container(
                      width: 84,
                      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: _page.mode == m ? AppColors.accent : Colors.transparent,
                            width: 2.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Stack(fit: StackFit.expand, children: [
                          if (snap.data != null)
                            Image.memory(snap.data![m]!, fit: BoxFit.cover, gaplessPlayback: true)
                          else
                            const ColoredBox(color: Colors.white10),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: double.infinity,
                              color: _page.mode == m ? AppColors.accent.withValues(alpha: .85) : Colors.black54,
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(scanModeLabels[m]!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white, fontSize: 12)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 도구 모음
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
            child: Row(children: [
              // 도구가 많아 옆으로 밀어서 보기
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    _Tool(Icons.add_photo_alternate_outlined, '추가하기', _busy ? null : _add),
                    _Tool(Icons.camera_alt_outlined, '다시 찍기', _busy ? null : _retake),
                    // 누르면 오른쪽 90°, 길게 누르면 왼쪽 90°
                    _Tool(Icons.rotate_right, '회전', _busy ? null : () => _rotate(1),
                        onLongPress: _busy ? null : () => _rotate(-1)),
                    _Tool(Icons.crop, '윤곽 수정', _busy ? null : _crop),
                    _Tool(Icons.crop_free_rounded, '영역 자르기', _busy ? null : _areaCrop),
                    // 누르면 이 페이지(다시 누르면 복원), 길게 누르면 모든 페이지
                    _Tool(_page.cutMask != null ? Icons.layers_clear_rounded : Icons.auto_awesome_rounded,
                        _page.cutMask != null ? '배경 복원' : '배경 제거', _busy ? null : _removeBg,
                        onLongPress: _busy ? null : () => _removeBg(all: true)),
                    _Tool(Icons.text_fields, '텍스트 추출', _busy ? null : _extractText),
                    _Tool(_page.cleaned ? Icons.auto_fix_off_rounded : Icons.auto_fix_high_rounded,
                        _page.cleaned ? '정리 취소' : '자동 정리', _busy ? null : _clean),
                    // 누르면 이 페이지, 길게 누르면 모든 페이지
                    _Tool(Icons.flare_rounded, '빛반사 제거', _busy ? null : _glare,
                        onLongPress: _busy ? null : () => _glare(all: true)),
                    _Tool(Icons.straighten_rounded, '기울기 보정', _busy ? null : _deskew,
                        onLongPress: _busy ? null : () => _deskew(all: true)),
                    _Tool(Icons.draw_rounded, '서명', _busy ? null : _sign),
                  ]),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    minimumSize: const Size(84, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_rounded, size: 22),
                  SizedBox(width: 4),
                  Text('완료', style: TextStyle(fontWeight: FontWeight.w800)),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  void _filterAllDialog(ScanMode m) => showDialog(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('\'${scanModeLabels[m]}\' 필터'),
          content: const Text('모든 페이지에 적용할까요?'),
          actions: [
            TextButton(
                onPressed: () {
                  Navigator.pop(d);
                  _setFilter(m);
                },
                child: const Text('이 페이지만')),
            FilledButton(
                onPressed: () {
                  Navigator.pop(d);
                  _setFilter(m, all: true);
                },
                child: const Text('모든 페이지')),
          ],
        ),
      );
}

class _Tool extends StatelessWidget {
  const _Tool(this.icon, this.label, this.onTap, {this.onLongPress});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 70,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

/// 원본 사진에 자동 인식된 윤곽(모서리·굴곡)을 그려 보여 주는 작은 창.
class _OutlinePreview extends StatelessWidget {
  const _OutlinePreview({required this.page, this.onTap});

  final ScanPage page;
  final VoidCallback? onTap;

  /// 원본 사진은 파일에서 읽을 수도 있어서 한 번만 읽어 둔다
  static final _cache = Expando<Uint8List>();

  @override
  Widget build(BuildContext context) {
    final d = page.det;
    final jpg = _cache[d] ??= d.jpg;
    const maxW = 92.0, maxH = 120.0;
    final s = (maxW / d.width).clamp(0.0, maxH / d.height);
    final w = d.width * s, h = d.height * s;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: w,
          height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white38),
            boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 10)],
          ),
          child: Stack(fit: StackFit.expand, children: [
            Image.memory(jpg, fit: BoxFit.fill, cacheWidth: 240, gaplessPlayback: true),
            CustomPaint(painter: _OutlinePainter(page.shape, s, page.shape.spread ? page.part : null)),
          ]),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.crop_rounded, size: 12, color: AppColors.accent),
            SizedBox(width: 4),
            Text('윤곽 수정', style: TextStyle(color: Colors.white, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }
}

class _OutlinePainter extends CustomPainter {
  _OutlinePainter(this.shape, this.scale, this.part);

  final PageShape shape;
  final double scale;

  /// 양면이면 이 페이지 쪽만 진하게
  final int? part;

  @override
  void paint(Canvas canvas, Size size) {
    Offset sc(Offset p) => p * scale;
    final outline = Path()..addPolygon([for (final p in shape.outline()) sc(p)], true);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), outline),
      Paint()..color = Colors.black45,
    );
    canvas.drawPath(
      outline,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    if (shape.spread) {
      canvas.drawLine(sc(shape.top[kMid]), sc(shape.bottom[kMid]),
          Paint()
            ..color = Colors.orangeAccent
            ..strokeWidth = 1.4);
    }
  }

  @override
  bool shouldRepaint(_OutlinePainter old) => old.shape != shape || old.scale != scale;
}

/// 되돌리기용: 페이지 목록과 각 페이지의 상태를 통째로 기억한다.
class _Snapshot {
  _Snapshot(this.pages, this.states, this.index);

  factory _Snapshot.of(List<ScanPage> pages, int index) => _Snapshot(
        List.of(pages),
        {
          for (final p in pages)
            p: (
              flat: p.flat,
              rawFlat: p.rawFlat,
              cutMask: p.cutMask,
              jpg: p.jpg,
              mode: p.mode,
              strength: p.strength,
              turns: p.quarterTurns,
              cleaned: p.cleaned,
              shape: p.shape,
              ocr: p.ocr,
              stamps: [for (final st in p.stamps) Stamp(st.png, st.rect, turns: st.turns)],
            ),
        },
        index,
      );

  final List<ScanPage> pages;
  final Map<
      ScanPage,
      ({
        Uint8List flat,
        Uint8List? rawFlat,
        Uint8List? cutMask,
        Uint8List jpg,
        ScanMode mode,
        double strength,
        int turns,
        bool cleaned,
        PageShape shape,
        OcrResult? ocr,
        List<Stamp> stamps,
      })> states;
  final int index;

  void restore(List<ScanPage> target) {
    target
      ..clear()
      ..addAll(pages);
    for (final MapEntry(key: p, value: s) in states.entries) {
      p
        ..flat = s.flat
        ..rawFlat = s.rawFlat
        ..cutMask = s.cutMask
        ..jpg = s.jpg
        ..mode = s.mode
        ..strength = s.strength
        ..quarterTurns = s.turns
        ..cleaned = s.cleaned
        ..shape = s.shape
        ..ocr = s.ocr;
      p.stamps
        ..clear()
        ..addAll(s.stamps);
    }
  }
}

/// 페이지 이미지 하나: 두 손가락으로 확대·이동(최대 6배), 두 번 누르면 확대/원래대로.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({super.key, required this.image, required this.onZoom});

  final Uint8List image;

  /// 확대 중인지 알린다 (확대 중에는 페이지 넘기기를 막는다)
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> {
  final _tc = TransformationController();
  bool _zoomed = false;
  Offset _tap = Offset.zero;

  @override
  void initState() {
    super.initState();
    _tc.addListener(() {
      final z = _tc.value.getMaxScaleOnAxis() > 1.02;
      if (z != _zoomed) {
        _zoomed = z;
        widget.onZoom(z);
      }
    });
  }

  @override
  void dispose() {
    // 확대한 채로 이 페이지가 바뀌면(다시 펴기·되돌리기·삭제) 확대 상태를 풀어 준다
    final cb = widget.onZoom;
    if (_zoomed) WidgetsBinding.instance.addPostFrameCallback((_) => cb(false));
    _tc.dispose();
    super.dispose();
  }

  void _doubleTap() {
    if (_zoomed) {
      _tc.value = Matrix4.identity();
    } else {
      const k = 2.5; // 누른 곳을 중심으로 2.5배
      _tc.value = Matrix4(k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1, 0, -_tap.dx * (k - 1), -_tap.dy * (k - 1), 0, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _tap = d.localPosition,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 6,
        child: Center(child: Image.memory(widget.image, gaplessPlayback: true)),
      ),
    );
  }
}
