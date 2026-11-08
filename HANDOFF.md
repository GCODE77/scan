# 북스캔 — 세션 핸드오프

- 최종 갱신: 2026-11-02
- 배포된 최신: **v0.27.0** (https://github.com/GCODE77/scan/releases/latest) — 2026-11-03 배포
- 저작권: © 2026 GLORY KIM
- 저장소: GCODE77/scan (main). 앱은 이 저장소의 최신 릴리스를 확인해 스스로 업데이트한다.

## 1. 무엇을 만드는 앱인가

휴대폰 카메라로 책·문서를 찍으면 스캐너로 스캔한 것처럼 반듯하게 펴서 PDF 등으로 저장하는 **안드로이드 앱**(Flutter). 모든 처리는 기기 안(오프라인). 사용자 본인이 쓰는 개인 앱이라 "클릭 수 줄이기", "눈에 보이는 결과 품질"이 최우선.

## 2. 파일 구조 (`lib/`)

| 파일 | 역할 |
|---|---|
| `main.dart` | 보관함(문서 목록·폴더·검색·선택 삭제), 앱 정보, 업데이트 확인 진입 |
| `document_screen.dart` | 문서 하나: 페이지 격자, 선택·순서 바꾸기, **저장/공유 호출**, OCR 큐, `_scan()` |
| `camera_screen.dart` | 연속 촬영, 실시간 윤곽, 자동 셔터, **흐림 경고**(`sharpness`) |
| `editor_screen.dart` | 편집: 필터·강도, 회전, 윤곽 수정, **영역 자르기**, **배경 제거**, **추가하기**, 다시 찍기, 자동 정리, **빛반사 제거·기울기 보정**, 서명, 되돌리기(스냅샷 20개) |
| `rect_crop_screen.dart` | **영역 자르기** 화면(사각형 8손잡이·비율 바로가기, 자르기/복사본으로 추가) |
| `crop_screen.dart` | **윤곽 수정**(점 8개) + 자석(모서리·변) |
| `scanner.dart` | OpenCV 엔진 전부: 검출, 펴기(`_dewarp`), 필터(`_applyMode`), 자석, 자동 정리, 빛반사, 기울기, 선명도, 긴 사진 |
| `save_sheet.dart` | 저장 시트(형식 6종 다중 선택, ZIP, 프리셋), `runSave`, PDF/DOCX 생성, 공유 시트 |
| `gallery_import.dart` | 갤러리에서 골라 자동 인식까지 한 뒤 페이지 목록 반환(`pickAndScan`) |
| `ocr.dart` | ML Kit OCR + `ScanPage` 모델(`flat`=편 원본, `jpg`=필터·회전 적용본) |
| `storage.dart` | 보관함 저장(`docs/<id>/doc.json` + 사진 파일), 윤곽 직렬화, 원본 줄이기 |
| `pdf_crypt.dart` | PDF 암호(RC4 40/128 호환 방식) |
| `signature.dart` | 서명 만들기·위치 잡기 |
| `updater.dart` | GitHub 최신 릴리스 확인 → 앱 안 설치(`ota_update`), 실패 시 웹 안내 |

## 3. 핵심 설계 (되돌리지 말 것)

1. **윤곽 모델 `PageShape`**: 위·아래 가장자리를 조절점 7개(`kPts`)의 Catmull-Rom 곡선으로, **좌우 변은 위·아래 모서리를 잇는 직선 + 가운데 휨 벡터(`leftBow`/`rightBow`)의 포물선**으로 표현. 펴기(`_dewarp`)는 격자 안쪽 점에 `bow*(4v(1-v))`를 더해 같이 휜다. 양면(spread)이면 제본선 쪽 변은 휘지 않는다. 저장 JSON에 `leftBow`/`rightBow`는 있을 때만 기록(없으면 0 → 옛 문서 호환).
2. **자석 두 겹**: ① `snapCorners`(L자 모서리 + 종이 색 + 흰 종이 3방식 투표, 놓은 곳 대각선 6% 안에서만) ② `snapEdgePoints`(v0.25.1에서 재작성): 변 위의 점마다 법선 방향 **Lab 색차**(밝기 절반 반영) 프로파일에서 경계 후보를 찾되, **경계 뒤가 계속 다른 색**이어야 인정(본문 글자 줄·접힌 선은 뒤에 종이가 다시 나와 탈락)하고 후보 중 **가장 바깥쪽의 뚜렷한 것**(최대 색차의 45% 이상)을 고른다. 점들은 RANSAC으로 모델에 맞춘다: 곡선(이차, 5점 중 4점이 6px 이내 + 휨이 변 길이의 8% 이내일 때만) → 직선(기울기 허용) → 일관성 없으면 **손대지 않음**. 모서리 자석 ①은 `_paperModel`을 쓴다.
   - **교훈(v0.25.0 실패 사례)**: 영수증 사진에서 종이-책상 밝기 차가 작고(L 182 vs 160) 색 차이(Lab b −5 vs +6)가 더 컸다. 이전 버전은 밝기 위주+가까운 경계 우선이라 대비가 센 **본문 마지막 글자 줄**에 붙어 아래 변이 W자로 휘었다. `tools/verify_snap_v3_real_receipt.py`가 이 사진 조건(윤곽 오버레이가 어둡게 덮은 스크린샷을 복원해서 사용)을 재현한다. **윤곽 화면 스크린샷은 바깥쪽이 54% 어둡게 덮여 있어 그대로 분석하면 안 됨** — 어둡게 덮인 영역을 /0.46으로 복원할 것. 자석 켬/끔 버튼이 둘 다 제어.
3. **OpenCV 모듈은 core·imgproc·imgcodecs만.** `photo`(inpaint 등)는 이 앱 빌드에 **없다**(호출하면 런타임에 symbol not found). 빛반사는 정규화 흐림(반사 아닌 곳의 색만 번지게)으로 직접 메운다. photo를 쓰려면 `pubspec.yaml`에 `hooks: user_defines: dartcv4: include_modules: [photo]`가 필요하고 OpenCV를 다시 빌드해야 함.
4. **빛반사 감지**: 전체 60번째 백분위 + 28 이상 밝고 채도 낮은 덩어리(면적 0.06%~50%), 글씨(주변보다 한참 어두운 점)는 덮어쓰지 않음. 종이가 이미 하얗(임계 ≥255)면 포기.
5. **저장은 "형식 집합"**: `SaveOptions.formats`(Set). 사진류(jpg·png·긴사진)는 갤러리 BookScan 앨범, PDF·TXT·DOCX·ZIP은 시스템 저장 창(파일마다 한 번씩). 공유는 한 번에 묶어서. 암호·워터마크는 프리셋에 저장하지 않음. OCR이 필요한 형식(txt·docx·검색 PDF)은 저장 전에 OCR 완료를 기다림.
6. **갤러리 불러오기는 카메라를 거치지 않는다**(`pickAndScan` → 바로 편집 화면). 편집 화면 "추가하기"는 현재 페이지 뒤에 삽입하고 `_push()`로 되돌리기 가능.
8. **배경 제거**(v0.26.0: ML Kit이 모델 다운로드 중이면 4초 간격 8회 재시도, 안 되거나 대상을 못 찾으면 GrabCut으로 대체, 둘 다 실패하면 그 페이지는 그대로): ML Kit `google_mlkit_subject_segmentation`(온디바이스, 첫 사용 때 모델 다운로드 가능). 확신도 마스크 → `buildCutMask`(원본 크기 PNG) → `ScanPage.cutMask`. `render()`가 마스크 밖을 흰색으로 칠하고(`applyCut`), **PNG 내보내기만 투명 배경**(`cutoutPng`), JPG·PDF는 흰 배경. 마스크는 편 이미지 방향 기준이라 회전은 `quarterTurns`로 같이 돌리고, 기울기 보정(`rotateMask`)·영역 자르기(`cropNorm`)도 마스크에 같이 적용. 저장은 `mask_<id>.png`. 윤곽 수정(재펴기)으로 새 페이지가 만들어지면 마스크는 사라짐.
9. **영역 자르기**는 화면(회전 반영)에서 고른 영역을 `_toFlatRect`로 편 이미지 좌표로 바꿔 자른다(Python으로 4방향 검증). 서명 위치는 어긋나므로 자르면 지운다. '복사본으로 추가'는 자른 이미지를 새 `Detection`의 원본으로 삼아 원래 페이지와 윤곽 그룹이 섞이지 않게 한다.
7. `ScanPage.render()`는 `ocr`을 비운다(좌표가 바뀌므로). 편 이미지를 직접 고치는 작업(`_fixFlat`)은 `p.flat` 교체 후 `render()`.

## 4. 빌드·배포 (함정 많음 — 꼭 읽기)

- **프로젝트 경로에 한글이 있으면 Gradle이 빌드를 거부**한다(`non-ASCII characters`). 반드시 ASCII 경로 복사본에서 빌드:
  ```
  B=C:/Users/yg.kim/AppData/Local/Temp/claude/scan_build
  cp -r lib assets android test pubspec.yaml pubspec.lock analysis_options.yaml .metadata $B/   # 최초 1회 전체, 이후 lib·pubspec만
  cd $B && flutter build apk --release --target-platform android-arm64
  ```
  빌드는 **오래 걸린다(12분~1시간 넘게)**. 결과: `$B/build/app/outputs/flutter-apk/app-release.apk`. 백그라운드로 돌리고 알림 대기. 알림의 exit code는 래퍼 값일 수 있으니 **로그의 `EXIT`와 APK 날짜를 직접 확인**.
- `flutter analyze`는 한글 경로에서 분석 서버가 죽는다 → ASCII 복사본(`.../scan_chk`)에서 `dart analyze lib` 사용.
- PC에서 OpenCV 네이티브 테스트는 불가(Visual Studio C++ 도구 없음). 알고리즘은 Python OpenCV로 옮겨 검증(`tools/verify_*.py`, 실행 시 `PYTHONIOENCODING=utf-8`).
- 서명은 debug 키(이전 릴리스와 동일해야 앱 안 업데이트가 덮어쓰기로 설치됨 — **서명 방식을 바꾸지 말 것**).
- **배포 절차**: ① `pubspec.yaml` 버전 올림(앱은 태그 `vX.Y.Z`가 현재보다 높을 때 알림) ② README·이 문서 갱신 ③ APK를 `BookScan.apk` 이름으로 복사 ④ `git add -A && git commit && git push origin HEAD` ⑤ `gh release create vX.Y.Z BookScan.apk --repo GCODE77/scan --title "..." --notes-file notes.md` (노트가 앱 업데이트 창에 그대로 보임) ⑥ 프로젝트 루트 `BookScan.apk`도 최신으로 복사(.gitignore에 `*.apk`).
- 한글이 섞인 코드 수정은 Python 치환보다 **Edit 도구**가 안전(유니코드·개행 불일치로 한 번 깨졌음). CRLF/LF 혼재 파일이 있으니 치환 시 개행 유지.

## 5. 검증 상태

| 항목 | 상태 |
|---|---|
| 정적 분석(`dart analyze`) | v0.24.0까지 통과 |
| 빛반사·기울기·선명도 알고리즘 | Python 이식 검증 완료 (기울기 2~5° 정확, 반사 비율 감지·글씨 보존, 흐림 구분) |
| 변 자석(`snapEdgePoints` v3) | Python 이식 검증: 합성 4종(책상·타일·색 종이·밝은 바닥) 47px→~1px, 실제 영수증 사진(v0.25.0 실패 사례)에서 아래·위 변이 종이 끝에 정확히 붙음. Dart 이식분은 PC 실행 불가(분석·공식 수치 검증만) |
| 독립 코드 검토(서브에이전트) | v0.26.0 직전에 12건 보고 → 코드로 확인된 항목 수정. 미수정: 기울기 보정 후 서명 ±6° 어긋남, 긴 사진 대용량 메모리 |
| **폰 실기기 테스트** | **v0.23.0, v0.24.0 모두 미실시** — 아래 체크리스트로 확인 필요 |

실기기 확인 체크리스트: 저장 시트에서 형식 여러 개(PDF+JPG+DOCX)·ZIP·프리셋 기억 / 긴 사진 / 빛반사 제거(실제 책 사진에서 민감도) / 기울기 보정 / 흐림 경고 임계값(40) / **배경 제거(영수증·명함·물건: 경계 품질, 첫 실행 모델 다운로드 안내, PNG 투명 저장)** / **영역 자르기(회전한 페이지, 복사본, 비율 바로가기)** / 윤곽 수정 8점(좌우 중간점 끌기→펴진 결과) / 변 자석이 엉뚱한 선(글씨·타일 줄눈)에 붙지 않는지 / 갤러리 가져오기→바로 편집 / 편집 "추가하기"+되돌리기 / 옛 문서(윤곽에 bow 없음) 열림.

## 6. 현재 상태와 다음 할 일

- **v0.27.0 (배포 완료)**: **앱 공유하기**(보관함 ⋮ 메뉴·앱 정보 → 소개 문구+받는 링크 `kAppLink`를 공유 창으로, `Updater.shareApp`). 받는 사람이 링크로 APK를 받으려면 저장소가 public이어야 함.
- v0.26.0 (배포 완료): 윤곽 수정 두 손가락 확대·이동(상대 이동 드래그), 손잡이 크기 축소, 편집 화면 두 손가락 확대(`_ZoomPage`), 배경 제거 보강(ML Kit 모델 다운로드 대기 재시도·읽을 수 있는 오류·**GrabCut 대체 `grabCutMask`**·매니페스트 `DEPENDENCIES`), 독립 코드 검토로 찾은 버그 수정(확대 상태 굳음, rawFlat 불일치, 일괄 작업 중 삭제, 자석 경합, ZIP 안내 불일치 등), 투명 PNG 흰 띠 완화
- v0.25.1 (배포 완료): 변 자석 재작성(위 교훈), 윤곽 수정 손잡이 색 구분(모서리=파랑, 변 가운데=분홍)
- v0.25.0 (배포 완료): 영역 자르기 + AI 배경 제거. 빌드 8분. **ML Kit 배경 제거는 폰에서만 동작 확인 가능 — 미검증**.
- v0.24.0 (배포 완료): 윤곽 8점(좌우 변 중간점) + 변 자석 + 갤러리→편집 직행 + 편집 "추가하기". 빌드는 12분 정도 걸렸음.
- 미구현 아이디어: Drive/OneDrive 직접 업로드(OAuth 필요 — 지금은 공유 시트로 대체), 변 자석이 여러 후보 중 고르는 UI, 흐림 임계값 사용자 조절, 페이지 격자의 흐림 표시.
- 사용자 선호: 답은 한국어. 동선(클릭 수)을 줄이는 제안을 환영. "최종본은 배포" = 릴리스까지 올리는 것.
