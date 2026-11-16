# 북스캔 고급 기능 도입 조사 (research.md)

* 작성: 2026-11-16 초안 v1, 같은 날 v2(적대적 검토 1차 review1.md 반영), v3(2차 review2.md 반영)
* 기준 코드: 북스캔 v0.28.0 (pubspec.yaml `version: 0.28.0+31`, 커밋 37576b3, APK 70,855,315바이트 = 67.6MiB)
* 이 문서는 조사 사실을 적는다. 무엇을 어떤 순서로 만들지는 plan.md에 있다. 판정표의 "대체안" 칸은 조사 결과로 가능한 것만 적었고, 넣을지는 plan.md와 오너 결정에서 정한다.

## 1. 프로젝트 정의와 용도

* 무엇: 경쟁 앱 CamScanner가 유료(고급계정)로 파는 기능 24개를 북스캔에 넣을 수 있는지 하나씩 판정하고, 넣을 수 있는 것은 구현 계획으로 넘긴다.
* 누구를 위해: 오너 한 명이 쓰는 개인 안드로이드 앱. 클릭 수를 줄이는 동선과 눈에 보이는 결과 품질이 최우선(HANDOFF.md §1).
* 전제: 앱은 오프라인 우선이고 모든 처리는 폰 안에서 한다. 운영할 서버가 없다. 무료 서버는 쓸 수 있으나 유료이거나 비용이 발생할 수 있는 것(유료 API, 유료 플랜, 사용량 과금, 초과 시 과금될 수 있게 카드를 등록해야 하는 서비스)은 쓰지 않는다.
* 판정 값 4가지
  * 이미 있음: v0.28.0 코드에 같은 기능이 있다(약하거나 부분이면 괄호로 적는다).
  * 온디바이스 구현: 폰 안에서, 비용 없이 만들 수 있다.
  * 서버·계정 필요(격상 후보): 외부 서비스가 필요하지만 무료로 쓸 수 있다는 근거를 찾았다. 오너가 직접 계정·앱 등록을 해야 하므로 plan.md의 마지막 단계로 둔다.
  * 서버·계정 필요(구현하지 않음): 유료이거나, 카드 등록이 필요하거나, 무료 한도가 불명확하거나, 서버를 계속 돌려야 한다. 대체안만 적는다.

## 2. 24개 항목 판정표

비용 열: 무료 확인 = 이번 조사에서 근거를 봤다 / 미확인 = 근거를 못 찾았다 / 유료 = 비용이 든다. 한 항목에 여러 조건이 있으면 나눠 적는다. 패키지 근거는 §4, 외부 서비스 근거는 §5.

| # | 항목 | 현재 북스캔 v0.28.0 (코드로 확인) | 판정 | 근거 (코드 위치 / 패키지) | 비용 |
|---|---|---|---|---|---|
| P1 | OCR 결과와 메모를 한 개의 편집 가능한 텍스트로 내보내기 | TXT·DOCX 내보내기는 있음. 문서·페이지 메모 기능은 없음 | 온디바이스 구현 | save_sheet.dart:496 `_txtBytes`, :609 `_buildDocx`. storage.dart:191~221 저장 필드에 메모 없음 | 무료 확인(새 의존성 없음) |
| P2 | 콜라주: 여러 페이지를 A4 한 장에 | 없음. 긴 사진(세로 이어붙임)만 있음 | 온디바이스 구현 | save_sheet.dart:431 `stitchLong`은 세로 이어붙이기뿐. `pdf` 패키지(이미 사용, :642 `_buildPdf`)로 격자 배치 가능 | 무료 확인(새 의존성 없음) |
| P3 | 책 모드: 좌우 페이지를 두 장으로 분할 | 있음. 제본선 자동 검출과 '양면 → 2장' 전환 | 이미 있음 | scanner.dart:302~320 `_findSpine`/`_inkGapSpine` → `spread`, crop_screen.dart:435 양면 전환 버튼, ocr.dart:42 `part` | 해당 없음 |
| P4 | 10GB 클라우드 저장 공간 | 없음. 문서는 앱 전용 폴더에만 있음 | 서버·계정 필요(격상 후보) | storage.dart:43 `getApplicationDocumentsDirectory()/docs`. 기기 백업·복원 파일(온디바이스)을 오너 본인 클라우드 무료 용량에 올리는 방식. Dropbox Basic 무료는 2GB(공식 페이지), Google 무료 15GB는 Gmail·사진과 공유(제3자 기사, 미확인). 10GB 별도 공간은 아님 | Dropbox: 앱 등록 무료 확인, 카드·정책 변경 미확인 / Google Drive API: 무료 확인, OAuth 등록 결제 요구 미확인 |
| P5 | 유효기간 있는 암호화 링크 공유 | 없음 | 서버·계정 필요(구현하지 않음) | 링크를 만들고 만료시키려면 파일을 올려 둘 서버가 필요. Supabase 무료는 1주 비활동 시 일시정지, Firebase Storage는 Blaze(카드) 필요, Cloudflare R2는 카드 요구 보고(§5). 대체: 암호 PDF(이미 있음) 또는 AES 암호 ZIP(archive 4.5.2 `ZipEncoder(password:)`)을 공유 시트로. 격상 단계가 생기면 그 서비스의 공유 링크로 재검토(무료 계정 링크 만료 기능은 미확인) | 무료 서버 후보는 미확인 또는 유료 조건 |
| P6 | Box·Google Drive·Dropbox·Evernote 자동 업로드 | 직접 업로드 없음. 공유 시트와 시스템 저장 창은 있음 | 서버·계정 필요(격상 후보: Dropbox, Google Drive / 미확인으로 보류: OneDrive, Box, Evernote) | save_sheet.dart:468 `SharePlus.share`, :484 `FilePicker.saveFile`(안드로이드 저장 창. Drive 앱이 있으면 저장 위치로 뜰 수 있음. Drive가 폴더 지정(트리 접근)을 지원해 "마지막 폴더로 바로 저장"이 되는지는 미확인, 폰 확인 필요). Dropbox는 PKCE로 비밀키 없이 가능(Dropbox 직원 답변·블로그, 공식 가이드 직접 확인은 리뷰어 쪽 접속 실패). OneDrive(Microsoft Graph)는 공개 클라이언트 PKCE가 가능하다는 제3자 자료뿐이고 Azure 유료 구독 필요 여부 미확인. Box는 PKCE 미확인, Evernote는 새 키 발급 불명. CamScanner의 "자동"(스캔 뒤 저절로 올림)과 "저장할 때 한 번 눌러 올림" 중 무엇으로 할지는 오너 결정 | Dropbox: 앱 등록 무료 확인, 카드 미확인 / Google Drive API 무료 확인 / OneDrive 미확인 / Box 미확인 / Evernote 미확인 |
| P7 | 전자서명 | 있음. 손글씨·글꼴 서명 만들기, 위치 잡아 얹기, 저장에 반영. 영역 자르기 하면 서명은 지워짐 | 이미 있음 | signature.dart:32 `makeSignature`, :343 `placeSignature`, ocr.dart:59 `stamps`, editor_screen.dart:224 자르기 시 `p.stamps.clear()`. 상대에게 보내 서명받기는 M10 | 해당 없음 |
| P8 | ID 카드 모드: 앞·뒤를 A4에 배치 | 없음 | 온디바이스 구현 | 영역 자르기(rect_crop_screen.dart)와 `pdf` 패키지로 A4 배치. 카드 실제 크기(85.6×54mm) 배치는 계산으로 가능 | 무료 확인(새 의존성 없음) |
| P9 | 비밀폴더(로컬 잠금 폴더) | 없음. 폴더는 있으나 잠금 없음. 문서는 이미 앱 전용 폴더에만 있음. 다만 매니페스트에 `allowBackup` 지정이 없고(AndroidManifest.xml:6 `<application`), `FLAG_SECURE` 사용 없음(lib·android grep 0건), 첫 페이지 썸네일 `thumb.jpg`를 문서마다 저장(storage.dart:185~188) | 온디바이스 구현 | main.dart:42 `_folder`, storage.dart:196 `folder`. 잠금 후보 `local_auth` 3.0.2(MainActivity를 `FlutterFragmentActivity`로 바꿔야 함, 현재 MainActivity.kt:5 `FlutterActivity`) 또는 앱 자체 PIN(`crypto` 이미 있음). 숨길 경로 목록은 plan.md 11단계 위협 모델 | 무료 확인(기기 생체인증 API, 외부 서비스 없음) |
| P10 | PDF 공유 시 암호 | 있음. RC4 128비트(오래되고 약한 방식). 입력은 ASCII 인쇄 가능 문자(기호 포함) 허용, 화면 부제는 "영문·숫자" | 이미 있음(약함) | pdf_crypt.dart:10~12 `PdfPasswordEncryption`(Revision 3, RC4), save_sheet.dart:647, 입력 필터 save_sheet.dart:295 `[\x21-\x7E]`. AES 암호화를 `pdf` 패키지로 할 수 있는지와 CamScanner 방식은 미확인 | 해당 없음 |
| P11 | 광고와 앱 워터마크 제거 | 원래 없음. 광고 패키지 없음, 결과물에 앱 표시 없음(PDF 메타데이터 creator만 '북스캔') | 이미 있음 | pubspec.yaml에 광고 의존성 없음(grep 0건), save_sheet.dart:646 `creator: '북스캔'` | 해당 없음 |
| P12 | 도용방지 워터마크 | PDF에만 있음. JPG·PNG·긴 사진에는 없고, 워터마크 스위치도 PDF를 골랐을 때만 보임 | 이미 있음(부분). 사진 보강은 온디바이스(새로 만드는 일에 포함) | save_sheet.dart:690 PDF 워터마크, :434~447 JPG·PNG 경로에 워터마크 없음, 스위치는 `if (hasPdf)` 블록 안(:245, :272 부근) | 무료 확인(새 의존성 없음) |
| P13 | 표 사진 → Excel(.xlsx) | 없음 | 온디바이스 구현(근사) | OCR 줄 위치(ocr.dart:12 `OcrLine.box`)를 행·열로 묶는 근사. xlsx는 DOCX처럼 직접 ZIP+XML 생성(save_sheet.dart:609 방식, `archive` 이미 있음). `excel` 패키지는 `pdf ^3.13`과 충돌로 설치 불가, `syncfusion_flutter_xlsio`는 상용 또는 무료 커뮤니티 라이선스 등록 필요 | 무료 확인(직접 생성 시 새 의존성 없음) |
| P14 | 번역(60여 종) | 없음 | 온디바이스 구현 | `google_mlkit_translation` 0.15.1(설치 가능, 59개 언어 열거, 한국어 있음). 언어 모델 약 30MB씩 첫 사용 때 내려받음(구글 문서) | 미확인(공식 문서에 비용 언급 없음. 온디바이스라 사용량 과금 경로는 없음) |
| M1 | OCR 41종 언어 | 한국어 인식기 하나(한글+라틴 문자). 중국어·일본어·데바나가리 없음 | 온디바이스 구현 | ocr.dart:86 `TextRecognitionScript.korean`, 라틴 문자 주석 ocr.dart:84, android/app/build.gradle.kts:56 `text-recognition-korean`. ML Kit은 5개 문자 체계, '지원' 37개 언어(구글 문서). 41개는 못 맞춤 | 미확인(P14와 같은 사유. 지금 OCR과 같은 조건) |
| M2 | 태그로 분류 | 폴더만 있음(문서당 하나) | 온디바이스 구현 | storage.dart:29 `folder`, :278 `setFolder`. 태그 필드 없음 | 무료 확인 |
| M3 | 손글씨·글자 주석 | 없음. 서명용 펜 그리기 부품은 있음. 서명 스탬프는 영역 자르기 때 모두 지워짐 | 온디바이스 구현 | signature.dart:327 `_StrokePainter`, 합성 함수 scanner.dart:1337 `stampPage`, 자르기 시 삭제 editor_screen.dart:223~226. 스탬프 방식을 그대로 쓰면 자르기에서 주석이 사라지므로 별도 레이어 설계 필요(plan.md 6단계) | 무료 확인 |
| M4 | 프린트 | 없음 | 온디바이스 구현 | `printing` 5.15.1(설치 가능, `Printing.layoutPdf`로 안드로이드 인쇄 창, 플러그인 minSdk 21) | 무료 확인(안드로이드 기본 인쇄 기능, 외부 서비스 없음) |
| M5 | 팩스 발송 | 없음 | 서버·계정 필요(구현하지 않음) | 무료로 계속 쓸 수 있는 팩스 API를 못 찾음. ClickSend 첫 25건, PamFax 3페이지 같은 체험분뿐이고 이후 유료(§5). 대체: PDF를 공유 시트로 팩스 앱·팩스 메일 서비스에 넘김 | 유료 |
| M6 | 기기 간 동기화 | 없음 | 서버·계정 필요(격상 후보, 부분) | 실시간 동기화는 서버 필요라 하지 않음. 같은 앱이 깔린 폰·태블릿 사이에서 백업 파일을 클라우드로 올리고 받는 수동 동기화만 후보. Dropbox 무료는 기기 3대 제한(공식 페이지·기사). API 앱 연결이 그 3대에 들어가는지는 미확인. PC에는 앱이 없어 백업 파일만 보임 | P4와 같음 |
| M7 | 공유자 초대, 같이 보기·리뷰 | 없음 | 서버·계정 필요(구현하지 않음) | 계정·권한·댓글 저장 서버가 상시 필요. Firebase Storage는 Blaze 필요, Supabase 무료는 비활동 일시정지 | 유료 또는 미확인 |
| M8 | PDF 모자이크(가리기) | 없음. 주의: 촬영 원본 `src_<id>.jpg`가 문서 폴더에 계속 저장되고(storage.dart:150~161), 윤곽 수정은 그 원본에서 다시 편다(editor_screen.dart:409 `warpFlat(p.det.jpg, shape)`). 자동 정리 되돌리기는 `rawFlat`으로 돌아간다(editor_screen.dart:118) | 온디바이스 구현(원본 처리 방식은 오너 결정) | OpenCV imgproc `resize`(축소 후 확대)로 모자이크, core·imgproc만으로 가능(HANDOFF.md §3). 편 이미지에만 구우면 원본·재펴기·정리 되돌리기·백업으로 가린 정보가 남는다. 설계 선택지는 plan.md 7단계. 안드로이드 자동 백업이 켜져 있으면 가리기 전 원본이 이미 구글 쪽에 있을 수 있음 | 무료 확인 |
| M9 | 검색 개선: 결과에서 바로 정리 | 검색은 문서 이름만. 선택 모드(길게 누르기, 폴더로·삭제)는 있음. OCR 글자는 doc.json에 저장되지만 `render()`가 매번 지우고(ocr.dart:76 `ocr = null`) 자동 OCR은 문서 화면을 열 때만 돈다(document_screen.dart:97~98) | 온디바이스 구현 | main.dart:306 `d.name.toLowerCase().contains`, main.dart:336 '문서 이름 검색', main.dart:419 길게 눌러 선택, storage.dart:215 OCR 저장. 필터를 바꾼 뒤 다시 열지 않은 페이지는 OCR이 비어 본문 검색에서 빠진다 | 무료 확인 |
| M10 | 서명 요청 | 없음 | 서버·계정 필요(구현하지 않음) | 상대에게 보내고 서명 상태를 추적하려면 서버 필요. 대체: PDF를 공유하고, 상대가 서명한 파일을 다시 받아 가져오기 | 유료 또는 미확인 |

집계 (24개)

| 판정 | 개수 | 항목 |
|---|---|---|
| 이미 있음 | 5 | P3, P7, P10(약함), P11, P12(부분) |
| 온디바이스 구현 | 12 | P1, P2, P8, P9, P13, P14, M1, M2, M3, M4, M8, M9 |
| 서버·계정 필요(격상 후보) | 3 | P4, P6(Dropbox·Google Drive만), M6(수동 동기화만) |
| 서버·계정 필요(구현하지 않음) | 4 | P5, M5, M7, M10 |
| 합계 | 24 | |

새로 만드는 일의 수: 온디바이스 12개 + P12 사진 워터마크 보강 1개 = 13개. 격상 후보 3개는 별도.

## 3. 초안 판정에서 고친 곳 (팀장 초안 대비)

1. M1: "한국어·영어만"을 "한국어 인식기 하나(한글+라틴 문자)"로 고침. 한국어 모델이 라틴 문자도 읽는다(ocr.dart:84 주석). 영어 외 라틴 문자 언어를 얼마나 읽는지는 미확인. CamScanner의 41종은 ML Kit '지원' 37개로 맞출 수 없다.
2. P12: 워터마크 스위치가 PDF를 골랐을 때만 화면에 보인다는 점 추가.
3. P9: 문서는 이미 앱 전용 폴더에만 있어 "로컬에만 저장"은 지금도 참. 새로 만들 것은 잠금·숨김과 우회 경로 차단(자동 백업, 최근 앱 미리보기, 백업 ZIP).
4. M9: 검색은 이름만 본다로 확정. OCR 본문은 doc.json에 있으나 비어 있는 페이지가 생길 수 있다.
5. P4, P6, M6: 오너 추가 제약(무료면 서버 허용)에 따라 "격상 후보"로 바꿈. P5, M5, M7, M10은 "구현하지 않음" 유지.
6. P13: `excel` 패키지 충돌 확인, 직접 생성으로.
7. P10: v2에서 "이미 있음(약함)"으로 낮춤(RC4).
8. M3, M8: v2에서 지금 데이터 흐름(자르기 시 스탬프 삭제, 원본 보관)과 부딪히는 점을 현재 열에 추가.

## 4. 선행 프로젝트(북스캔 v0.28.0)에서 재사용하는 것과 새 패키지

### 4.1 재사용

| 재사용 대상 | 위치 | 쓰는 곳 |
|---|---|---|
| PDF 생성(글꼴 내장, A4 배치) | save_sheet.dart:642 `_buildPdf` | P2, P8, M4, P12 |
| DOCX 직접 생성(ZIP+XML) | save_sheet.dart:609 `_buildDocx` | P1, P13 xlsx 생성 방식 |
| 이미지 합성 | scanner.dart:1337 `stampPage` | P12 사진 워터마크, M3 글자 주석 합성 |
| 펜 그리기 | signature.dart:327 `_StrokePainter` | M3 손글씨 입력 화면 |
| 영역 자르기 화면과 좌표 변환 | rect_crop_screen.dart, editor_screen.dart `_toFlatRect`, `cropNorm` | P8, M8 영역 고르기, M3 자르기 시 좌표 재계산 |
| 문서 저장 형식 doc.json | storage.dart:143~238 `_save`, :81~86 `_docFrom`, 불러오기 `load` :89~131, 직접 쓰기 `setFolder` :278~286, `shrinkOriginals` :312~357 | M2, P1, P9, M3 (load·save·keep과 직접 쓰기 경로 모두 고쳐야 함) |
| OCR 결과(줄 글자와 위치) | ocr.dart:12 `OcrLine` | M9, P13, P14 |
| 선택 모드와 일괄 작업 | main.dart:143 `_selectMode`, :419 | M9, M2 |
| ZIP | `archive` 4.5.2 (pubspec.lock) | 백업 파일, P5 대체 암호 ZIP |
| 공유·저장 창 | save_sheet.dart:468, :484 | P6 대체, M5 대체 |

### 4.2 저장 구조에 대한 사실 (새 필드를 얹을 때의 위험)

* `Store._save`는 doc.json을 아는 필드만으로 새로 쓴다(storage.dart:191~221). 모르는 필드는 저장할 때 사라진다.
* 저장 끝에 `keep` 목록에 없는 파일을 모두 지운다(storage.dart:147 `keep` 시작, :233~236 삭제). 새 파일(주석 이미지 등)은 `keep`에 넣지 않으면 저장 때 지워진다.
* 직렬화가 `File`·`path_provider`와 붙어 있어 지금은 순수 함수 테스트가 안 된다(storage.dart:42~45). 테스트하려면 JSON 변환을 떼어 내는 리팩터가 필요하다.
* `test/detect_test.dart` 한 개가 있으나 `flutter test` 실행 기록은 HANDOFF.md에 없다. 지금 환경에서 도는지 미확인.
* `setFolder`(storage.dart:278~286)와 `shrinkOriginals`(storage.dart:312~357)는 `_save`를 거치지 않고 doc.json을 바꿔치기 없이 직접 쓴다(:284, :355).
* 지금 저장 창 `FilePicker.saveFile`(save_sheet.dart:484)은 file_picker 13.1.0에서 `required Uint8List bytes`(Pub 캐시 file_picker.dart:169~171)라 큰 파일도 전체를 메모리에 올려야 한다. 백업처럼 큰 파일을 저장하려면 다른 경로가 필요하다(plan.md 1단계, Q13).
* `rawFlat`(자동 정리 전 이미지)은 저장하지 않고 앱이 켜져 있는 동안만 메모리에 있다(ocr.dart:51~52, storage.dart에 저장 코드 없음).

### 4.3 새 패키지 확인 결과

확인 방법: `C:\Users\yg.kim\AppData\Local\Temp\claude\scan_chk`에서 `flutter pub add --dry-run`(pubspec.yaml 수정 시각 2026-11-09 07:21 그대로) 과 Pub 캐시의 README·소스 읽기. 확인일 2026-11-16.

| 패키지 | dry-run 결과 | 확인한 내용 | APK 증가 | 비용 |
|---|---|---|---|---|
| printing | 5.15.1 설치 가능 | `Printing.layoutPdf`, `sharePdf` 있음(printing.dart:52, :197), android minSdk 21 | 미확인(1MB 미만 추정) | 무료 확인(안드로이드 인쇄 프레임워크) |
| google_mlkit_translation | 0.15.1 설치 가능(1.0.3은 지금 의존성으로 안 됨) | 59개 언어 열거, 한국어 있음, `downloadModel`, android `com.google.mlkit:translate:17.0.3`. 구글 문서: 모델 약 30MB, Wi-Fi에서만 받기 권장 | 미확인. 모델은 APK가 아니라 폰 저장공간에 언어당 약 30MB | 미확인(ML Kit 문서·약관에 비용 문구 없음. 약관: 입력 데이터와 결과는 구글 서버로 보내지 않지만, 버그 수정·모델 갱신·하드웨어 호환 정보를 위해 구글 서버와 통신할 수 있고 성능·사용 지표를 보냄) |
| google_mlkit_text_recognition 추가 문자 체계 | 이미 0.17.1 사용 | 중국어·데바나가리·일본어 모델은 `compileOnly`라 앱 gradle에 직접 추가 | 구글 문서: 앱에 묶으면 체계당 아키텍처당 약 4MB, Play 서비스 방식은 약 260KB. arm64 하나에 3개 묶으면 약 12MB(문서 수치로 계산한 추정) | 미확인(위와 같음) |
| local_auth | 3.0.2 설치 가능 | 생체인증, 기본은 PIN·패턴 대체 허용, `FlutterFragmentActivity` 필요, android minSdk 24 | 미확인(작음 추정) | 무료 확인(기기 기능) |
| excel | 설치 불가 | `pdf >=3.13.0`이 `xml ^7.0.1`을 요구해 충돌 | 해당 없음 | 해당 없음 |
| syncfusion_flutter_xlsio | 35.1.46 설치 가능 | README: 상용 패키지, 상용 또는 무료 커뮤니티 라이선스 필요 | 미확인 | 미확인(라이선스 등록 조건) → 쓰지 않음 |
| flutter_web_auth_2 | 5.1.0 설치 가능 | Dropbox PKCE 로그인 창용 후보. 동작은 폰에서만 확인 가능 | 미확인 | 무료 확인(오픈소스) |
| google_sign_in / googleapis | 7.2.0 / 19.0.0 설치 가능 | Google Drive 후보. README는 읽지 않음 | 미확인 | 패키지는 무료, Drive API는 §5 |
| http | 이미 다른 패키지 경유로 들어 있음 | | 0 | 무료 |

## 5. 외부 서비스 조사 (무료 여부)

확인일 2026-11-16. 웹 검색 요약과 공식 문서 일부 읽기. 제3자 자료만 근거인 것은 미확인으로 둔다. "본 내용" 칸은 출처에서 확인한 문장의 요지.

| 서비스 | 무료 한도 | 카드 등록 | 비활동 정지 | 무료 플랜 변경 위험 | 판정 | 출처와 본 내용 |
|---|---|---|---|---|---|---|
| Dropbox API | 앱 등록 무료. 개발 상태 앱은 본인 계정으로 바로 쓰고 최대 500명. Basic 무료 계정 2GB, 기기 3대 | 미확인(요구한다는 근거도 못 찾음) | 근거 못 찾음 | 미확인. 기기 3대 제한은 2019년 3월에 새로 생긴 전례가 있음(https://venturebeat.com/business/dropbox-now-limits-free-users-to-3-devices , 제3자 기사) | 격상 후보 | developer-guide(개발 상태 500명, 50명 넘으면 2주 안 프로덕션 신청), dropbox.tech PKCE 글과 포럼 직원 답변(PKCE는 비밀키 없이), dropbox.com/basic(무료 2GB, 기기 3대). https://www.dropbox.com/developers/reference/developer-guide , https://dropbox.tech/developers/pkce--what-and-why- , https://www.dropbox.com/basic |
| Google Drive API | 공식 사용 한도 페이지: 추가 요금 없음, 초과는 오류로 막힘. 저장 용량은 계정 무료 15GB를 Gmail·사진과 공유(제3자 기사, 미확인) | OAuth 클라이언트 등록에 결제 계정 필요 여부 미확인 | 근거 못 찾음 | 미확인 | 격상 후보(조건부). 동의 화면 '테스트' 상태면 갱신 토큰 7일 만료(매주 재로그인). 프로덕션 전환 시 `drive.file` 검증 필요 여부 미확인. 앱이 debug 키로 서명되어 그 SHA-1 등록 필요 | https://developers.google.com/workspace/drive/api/guides/limits (요금 없음, 초과 시 403·429), https://developers.google.com/identity/protocols/oauth2/production-readiness/overview (테스트 상태 7일 만료, 100명) |
| Google Drive (안드로이드 저장 창) | OAuth 없이 시스템 저장 창에서 Drive 선택 | 불필요 | 해당 없음 | 해당 없음 | 지금도 가능(파일마다 위치 선택). 폴더 지정 후 반복 저장(트리 접근)을 Drive가 지원하는지 미확인, 폰 확인 | 검색에서 Drive 관련 공식 근거 못 찾음 |
| OneDrive (Microsoft Graph) | 미확인 | Azure 구독 필요 여부 미확인(제3자: Azure 계정 무료) | 미확인 | 미확인 | 보류(미확인). 공개 클라이언트 PKCE 가능이라는 제3자 자료만 있음. HANDOFF.md:79에 오너가 원했던 대상으로 적혀 있음 | https://learn.microsoft.com/en-us/onedrive/developer/rest-api/getting-started/app-registration (앱 등록 절차 존재, 비용 문구 확인 못 함) |
| Box | 무료 개발자 계정으로 OAuth 2.0 앱 생성 가능 | 미확인 | 미확인 | 미확인 | 보류(미확인). PKCE 지원 미확인, 앱 안에 client secret이 필요할 가능성(기능 요청 글) | https://developer.box.com/guides/getting-started/free-developer-plan |
| Evernote | 키는 문의 양식으로 수동 승인(옛 문서). 새 키 발급 중단 주장(제3자) | 미확인 | 미확인 | 미확인 | 보류(미확인) | 공식 확인 못 함 |
| Supabase 무료 | 파일 저장 1GB, 프로젝트 2개 | 미확인 | 1주 비활동 시 일시정지, 수동 재개 | 미확인 | 구현하지 않음 | https://supabase.com/pricing (무료 1GB 파일, 1주 비활동 일시정지) |
| Cloudflare Workers / KV / R2 | Workers 하루 10만 요청, KV 하루 읽기 10만·쓰기 1천, R2 10GB-월 | R2 버킷 생성 전 결제수단 요구(제3자 보고). Workers 무카드는 미확인 | 미확인 | R2 초과분 과금(차단 아님) | 구현하지 않음 | https://developers.cloudflare.com/workers/about/limits/ , https://developers.cloudflare.com/kv/platform/limits , https://developers.cloudflare.com/r2/pricing/ |
| Firebase Spark | Firestore 등 무료 한도(수치 확인 안 함) | 미확인 | 미확인 | 확인됨: Cloud Storage는 새 기본 버킷에 Blaze 필요, 2026-02-03부터 Spark 프로젝트는 Storage 읽기·쓰기 접근을 잃음(공식 FAQ) | 구현하지 않음(파일 저장이 Blaze=카드) | https://firebase.google.com/docs/storage/faqs-storage-changes-announced-sept-2024 |
| GitHub | 앱 업데이트용 공개 릴리스는 지금도 무료로 사용 중 | 불필요 | 해당 없음 | 미확인 | 문서 저장소로는 쓰지 않음. 개인 토큰을 앱에 넣어야 하고 약관상 용도 문제 가능성(미확인) | 조사 안 함 |
| 팩스 API (ClickSend, PamFax 등) | 체험분만(ClickSend 첫 25건, PamFax 3페이지 보고) | 체험 후 유료, eFax 등은 카드 필요 보고 | 해당 없음 | 해당 없음 | 구현하지 않음 | https://www.clicksend.com/in/fax/fax-api/ , https://pamfax.biz/developers/introduction |
| ML Kit(번역·OCR 추가 문자) | 온디바이스 처리 | 불필요 | 해당 없음 | 미확인 | 온디바이스 구현 | https://developers.google.com/ml-kit/language/translation/android (모델 약 30MB, Wi-Fi 권장), https://developers.google.com/ml-kit/vision/text-recognition/v2/languages (지원 37개), https://developers.google.com/ml-kit/vision/text-recognition/v2/android (체계당 약 4MB 또는 260KB), https://developers.google.com/ml-kit/terms (입력 데이터·결과 미전송, 단 모델 갱신 등 서버 통신과 성능·사용 지표 전송 있음) |

## 6. 데이터와 출처

* 앱 코드: `lib/*.dart`, `android/` 직접 grep·읽기(줄 번호는 v0.28.0, 커밋 37576b3 기준).
* 설계·빌드 함정: HANDOFF.md(2026-11-02 갱신), README.md.
* 패키지: Pub 캐시 README·소스, scan_chk dry-run.
* 외부 서비스: §5 표의 URL(2026-11-16 검색). 24개 항목 설명은 오너가 준 CamScanner 스크린샷 문구를 팀장이 옮긴 것이고, CamScanner 실제 동작은 확인하지 않았다.
* 새로 생기는 사용자 데이터: 메모·태그·잠금 표시·주석 좌표는 doc.json에, 글자 주석 이미지는 문서 폴더 파일로, 백업 파일은 ZIP. 모두 폰 안. 격상 후보를 구현하면 백업 ZIP이 오너 본인 클라우드로 나간다.

## 7. 확정된 결정

오너가 정했거나 규칙·조사로 강제되는 것만 적는다. 에이전트가 고른 것은 plan.md "오너 결정 필요"에 있다.

| 번호 | 결정 | 근거 |
|---|---|---|
| D1 | 비용이 생길 수 있는 서비스는 쓰지 않는다. 무료 근거가 확인된 외부 서비스만 마지막 단계 후보로 둔다 | 오너 제약(2026-11-16 추가) |
| D2 | 처리는 폰 안에서 한다. 이미지·OCR 글자를 외부 AI 서비스로 보내지 않는다 | HANDOFF.md §1 |
| D3 | 무료 근거가 없는 P5, M5, M7, M10은 구현하지 않고 대체안만 검토한다 | D1과 §5 조사 |
| D4 | OpenCV photo 모듈은 추가하지 않는다 | HANDOFF.md §3, 오너 제약 |
| D5 | 사용자에게 보이는 알림·오류는 한국어 문장으로. 내부 오류 코드를 그대로 띄우지 않는다 | 오너 선호 |
| D6 | 서명 키(debug 키)와 업데이트 방식은 바꾸지 않는다 | HANDOFF.md §4 |
| D7 | 코드 전에 오너 승인 게이트를 통과한다 | CLAUDE.md §7 |

(v1의 "xlsx 직접 생성", "doc.json 새 필드 기본값 호환"은 기술 설계라 plan.md로 옮겼다.)

## 8. 확인이 필요한 것

### 8.1 오너 결정 필요

plan.md "오너 결정 필요" 목록이 원본이다(중복을 피해 여기에는 적지 않는다).

### 8.2 미확인 목록

* ML Kit 번역·추가 OCR 모델의 비용 문구, 번역 라이브러리의 APK 증가량.
* `printing`, `local_auth`, `flutter_web_auth_2`의 APK 증가량.
* 한국어 OCR 모델이 라틴 문자 외국어(악센트 포함)를 읽는 품질.
* Google OAuth 클라이언트 등록에 결제 계정이 필요한지, `drive.file`만 쓰면 검증 없이 프로덕션 전환이 되는지, Google 무료 용량 수치(공식).
* Google Drive가 안드로이드 저장 창에서 폴더 지정(트리 접근)을 지원하는지(폰 확인).
* Dropbox 앱 등록 시 카드 요구 여부, API 연결이 Basic 기기 3대에 들어가는지, 공식 OAuth 가이드 직접 확인.
* OneDrive(Microsoft Graph): Azure 유료 구독 필요 여부, 개인 계정 PKCE 공식 근거.
* Box PKCE, Evernote 새 키 발급, Supabase·Cloudflare Workers 카드 요구.
* 무료 클라우드 공유 링크의 만료 기능(P5 재검토용).
* `pdf` 패키지로 AES PDF 암호가 가능한지(P10 보강용), 윈도우 기본 압축 해제가 AES ZIP을 여는지.
* `flutter test`가 scan_chk에서 도는지.
* 안드로이드 자동 백업이 이 앱 문서를 실제로 올리는지(크기 제한 등).
* CamScanner 각 기능의 실제 동작.

## 9. 적대적 검증 기록

* 규약은 Opus 리뷰어와 Codex 동시 검토지만, 이 세션에서는 Codex를 쓸 수 없어 경과를 모르는 Opus 리뷰어 2회만 했다.
* 1차: 2026-11-16, 62/100 (docs/review1.md). 높음 4건은 팀장이 원자료로 확인. 나머지는 설계 담당이 코드·문서로 직접 확인.
* 2차: 2026-11-16, 78/100 (docs/review2.md). 이 문서 관련 지적은 아래 표 끝에 추가. 독립 채점은 2회로 종료, 이후 기계 검사만.
* 이 문서와 관련된 지적만 적는다. 전체 30건 표는 plan.md "적대적 검증 기록".

| 지적 | 반영 여부 | 근거 |
|---|---|---|
| A-2 P10 "영문·숫자만" 틀림 | 반영 | save_sheet.dart:295 필터 `[\x21-\x7E]` 확인. P10 행 수정 |
| A-3 ocr.dart:85 주석 위치 | 반영 | 주석은 ocr.dart:84 확인. M1 행·§3 수정 |
| A-4 `stampPage` 위치 누락 | 반영 | scanner.dart:1337 확인. M3 행·§4.1 수정 |
| A-5 M9 OCR이 `render()`로 비는 경로 누락 | 반영 | ocr.dart:76, document_screen.dart:97~98 확인. M9 행 수정, plan 3단계(v3 번호) 합격 기준에 반영 |
| B-1 Dropbox "무료 확인"이 근거보다 강함 | 반영 | §5 카드·정책 미확인과 맞춰 P4·P6 비용 칸을 나눠 적음 |
| B-2 Firebase "카드 불필요(일반 상식)" | 반영 | 근거 없는 문구 삭제, 미확인으로 |
| B-3 URL별 본 내용 없음 | 반영 | §5 "출처와 본 내용" 칸으로 바꿈 |
| C-1 OneDrive 누락 | 반영 | HANDOFF.md:79 확인. §5에 행 추가, 근거가 제3자뿐이라 보류(미확인) |
| C-2 Drive를 OAuth 없이 쓰는 길 덜 팜 | 반영 | 트리 접근 지원은 검색으로 확인 못 함. 미확인으로 두고 plan 0단계 폰 확인 목록에 넣음 |
| C-3 용량 근거 없이 Dropbox 우선 | 반영 | Dropbox 2GB(공식), Google 15GB 공유(미확인) 추가. 우선순위는 오너 결정으로 옮김 |
| C-4 자동 업로드를 수동으로 바꿈 | 반영 | P6 행에 적고 오너 결정으로 |
| C-5 P5 부분 대체 재검토 | 반영 | P5 행에 "격상 단계 후 재검토", 미확인 목록에 링크 만료 기능 |
| C-6 P10 RC4 약함 | 반영 | "이미 있음(약함)", AES 가능 여부 미확인 목록 |
| C-7 P12 집계 중복 | 반영 | "새로 만드는 일 13개" 문장 추가 |
| E research에 계획 성격 섞임 | 반영(부분) | §7에서 기술 설계 결정을 plan으로 옮김. 판정표 대체안 칸은 조사 결과라 유지 |
| 2차 낮음 1: `_docFrom`·`load`·`stamps` 줄 번호 | 반영 | storage.dart:81~86, :89~131, ocr.dart:59 확인. §4.1, P7 행 수정 |
| 2차 낮음 3: 기기 3대 2019 출처 없음 | 반영 | §5 Dropbox 행에 출처 URL(제3자 기사) |
| 2차 C-8: ML Kit "데이터 미전송" 과장 | 반영 | 약관 페이지(2026-11-16 읽음)에 서버 통신·사용 지표 전송 문구 있음. §4.3, §5 수정 |
| 2차 C-1: 직접 쓰기 경로 누락 | 반영 | storage.dart:278~286, :312~357 확인. §4.1, §4.2 |
| 2차 H-1: `saveFile` 바이트 전체 요구 | 반영 | file_picker.dart:169~171 확인. §4.2에 사실 추가, 설계는 plan.md 1단계 |
| 2차 C-3: 모자이크와 자동 백업 | 반영 | M8 행에 추가 |
