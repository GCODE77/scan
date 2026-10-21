# 북스캔 (scan)

휴대폰 카메라로 책을 찍으면 진짜 스캐너로 스캔한 것처럼 만들어 주는 안드로이드 앱입니다.

## 설치
[Releases](https://github.com/GCODE77/scan/releases/latest)에서 `BookScan.apk`를 휴대폰으로 받아 설치하세요.
(처음 설치할 때 "출처를 알 수 없는 앱 설치 허용"이 필요합니다.)

## 기능
- 셔터만 누르면 연속 촬영, 페이지 윤곽·굴곡을 자동 인식해서 반듯하게 펴기
- 펼친 양면 → 제본선 검출 후 두 페이지로 자동 분리
- 편집 화면: 필터(원본·밝게하기·매직 컬러·흑백·스캔 B/W), 회전, 사진 자르기, 다시 찍기, 비교
- 한국어·영어 OCR (텍스트 추출·복사)
- 저장: 글자 검색 가능한 PDF / 사진(JPG) / 텍스트 — 원하는 페이지만 골라서도 가능
- 문서 보관함: 앱을 닫아도 문서가 남음, 이름 바꾸기·검색·삭제, 페이지 순서 바꾸기
- 모든 처리는 휴대폰 안에서 (오프라인)

## 빌드
Flutter 3.47 + Android SDK 36 + JDK 17, OpenCV(`opencv_dart`) 컴파일에 CMake/Ninja 필요.

```
flutter build apk --release --target-platform android-arm64
```
