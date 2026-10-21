# 북스캔 (scan)

휴대폰 카메라로 책을 찍으면 진짜 스캐너로 스캔한 것처럼 만들어 주는 안드로이드 앱입니다.

## 설치
[Releases](https://github.com/GCODE77/scan/releases/latest)에서 `BookScan.apk`를 휴대폰으로 받아 설치하세요.
(처음 설치할 때 "출처를 알 수 없는 앱 설치 허용"이 필요합니다.)

## 기능
- 촬영 → 페이지 모서리 자동 검출, 손가락으로 미세 조정 (확대경)
- 책 굴곡 추적 및 펴기 (위·아래 가장자리 곡선 기반)
- 펼친 양면 → 제본선 검출 후 두 페이지로 자동 분리
- 색 보정: 원본 / 선명하게(그림자 제거) / 흑백 / 스캔(B/W)
- PDF로 저장·공유, 사진으로 갤러리 저장
- 모든 처리는 휴대폰 안에서 (오프라인)

## 예정
- 한국어·영어 OCR, 검색 가능한 PDF

## 빌드
Flutter 3.47 + Android SDK 36 + JDK 17, OpenCV(`opencv_dart`) 컴파일에 CMake/Ninja 필요.

```
flutter build apk --release --target-platform android-arm64
```
