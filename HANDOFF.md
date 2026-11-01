# 북스캔 — 세션 핸드오프

- 최종 갱신: 2026-11-02
- 배포된 최신: **v0.24.0** (https://github.com/GCODE77/scan/releases/latest) — 2026-11-02 배포
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
| `editor_screen.dart` | 편집: 필터·강도, 회전, 자르기, **추가하기**, 다시 찍기, 자동 정리, **빛반사 제거·기울기 보정**, 서명, 되돌리기(스냅샷 20개) |
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
2. **자석 두 겹**: ① `snapCorners`(L자 모서리 + 종이 색 + 흰 종이 3방식 투표, 놓은 곳 대각선 6% 안에서만) ② `snapEdgePoints`(변 위의 점들을 법선 방향으로 훑어 "안쪽은 종이, 바깥은 아님" 경계 중 대비 크고 가까운 것에 붙임, 중앙값에서 크게 벗어난 점은 중앙값으로, 60% 미만 발견이면 아무것도 안 함). 둘 다 `_paperModel`(종이 판정 기준)을 공유. 자석 켬/끔 버튼이 둘 다 제어.
3. **OpenCV 모듈은 core·imgproc·imgcodecs만.** `photo`(inpaint 등)는 이 앱 빌드에 **없다**(호출하면 런타임에 symbol not found). 빛반사는 정규화 흐림(반사 아닌 곳의 색만 번지게)으로 직접 메운다. photo를 쓰려면 `pubspec.yaml`에 `hooks: user_defines: dartcv4: include_modules: [photo]`가 필요하고 OpenCV를 다시 빌드해야 함.
4. **빛반사 감지**: 전체 60번째 백분위 + 28 이상 밝고 채도 낮은 덩어리(면적 0.06%~50%), 글씨(주변보다 한참 어두운 점)는 덮어쓰지 않음. 종이가 이미 하얗(임계 ≥255)면 포기.
5. **저장은 "형식 집합"**: `SaveOptions.formats`(Set). 사진류(jpg·png·긴사진)는 갤러리 BookScan 앨범, PDF·TXT·DOCX·ZIP은 시스템 저장 창(파일마다 한 번씩). 공유는 한 번에 묶어서. 암호·워터마크는 프리셋에 저장하지 않음. OCR이 필요한 형식(txt·docx·검색 PDF)은 저장 전에 OCR 완료를 기다림.
6. **갤러리 불러오기는 카메라를 거치지 않는다**(`pickAndScan` → 바로 편집 화면). 편집 화면 "추가하기"는 현재 페이지 뒤에 삽입하고 `_push()`로 되돌리기 가능.
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
| 변 자석(`snapEdgePoints`) | Python 이식 검증: 곡선 변이 평균 47px 어긋난 합성 사진에서 1~2px로 붙음(책상·타일·색 종이·밝은 바닥) |
| **폰 실기기 테스트** | **v0.23.0, v0.24.0 모두 미실시** — 아래 체크리스트로 확인 필요 |

실기기 확인 체크리스트: 저장 시트에서 형식 여러 개(PDF+JPG+DOCX)·ZIP·프리셋 기억 / 긴 사진 / 빛반사 제거(실제 책 사진에서 민감도) / 기울기 보정 / 흐림 경고 임계값(40) / 윤곽 수정 8점(좌우 중간점 끌기→펴진 결과) / 변 자석이 엉뚱한 선(글씨·타일 줄눈)에 붙지 않는지 / 갤러리 가져오기→바로 편집 / 편집 "추가하기"+되돌리기 / 옛 문서(윤곽에 bow 없음) 열림.

## 6. 현재 상태와 다음 할 일

- **v0.24.0 (배포 완료)**: 윤곽 8점(좌우 변 중간점) + 변 자석 + 갤러리→편집 직행 + 편집 "추가하기". 빌드는 12분 정도 걸렸음.
- 검토 중: **AI 배경제거**(영수증·명함·물건·서명 추출용). 온디바이스(ML Kit `google_mlkit_subject_segmentation 0.2.1`)만 사용, 편집 화면 선택 도구로. 미착수.
- 미구현 아이디어: Drive/OneDrive 직접 업로드(OAuth 필요 — 지금은 공유 시트로 대체), 변 자석이 여러 후보 중 고르는 UI, 흐림 임계값 사용자 조절, 페이지 격자의 흐림 표시.
- 사용자 선호: 답은 한국어. 동선(클릭 수)을 줄이는 제안을 환영. "최종본은 배포" = 릴리스까지 올리는 것.
