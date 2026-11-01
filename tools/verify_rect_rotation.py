"""영역 자르기: 회전된 화면에서 고른 영역을 편 이미지 좌표로 바꾸는 식(_toFlatRect) 검증."""
import cv2
import numpy as np

ROT = {0: None, 1: cv2.ROTATE_90_CLOCKWISE, 2: cv2.ROTATE_180, 3: cv2.ROTATE_90_COUNTERCLOCKWISE}


def to_flat(v, q):  # v = (l, t, r, b) 0~1, editor_screen.dart 의 _toFlatRect 와 같은 식
    l, t, r, b = v
    return {1: (t, 1 - r, b, 1 - l), 2: (1 - r, 1 - b, 1 - l, 1 - t), 3: (1 - b, l, 1 - t, r)}.get(q, v)


def crop(img, r):
    h, w = img.shape[:2]
    x0, y0 = round(r[0] * w), round(r[1] * h)
    x1, y1 = round(r[2] * w), round(r[3] * h)
    return img[y0:y1, x0:x1]


rng = np.random.default_rng(1)
flat = rng.integers(0, 255, (400, 300), dtype=np.uint8)  # 세로 이미지(비대칭이라 방향 오류가 드러남)
ok = True
for q in range(4):
    view = flat if ROT[q] is None else cv2.rotate(flat, ROT[q])
    vr = (0.15, 0.25, 0.70, 0.60)  # 사용자가 화면에서 고른 영역
    want = crop(view, vr)  # 화면에서 본 그대로 자른 결과
    got = crop(flat, to_flat(vr, q))
    got = got if ROT[q] is None else cv2.rotate(got, ROT[q])  # 편 이미지를 자른 뒤 같은 회전
    same = want.shape == got.shape and np.abs(want.astype(int) - got.astype(int)).max() <= 0
    print(f'회전 {q * 90}°: 일치={same} 크기 {want.shape} / {got.shape}')
    ok &= same
print('모두 일치' if ok else '불일치 있음')
