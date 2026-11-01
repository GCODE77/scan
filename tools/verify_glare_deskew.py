"""scanner.dart의 새 알고리즘(빛 반사 메우기, 기울기 보정, 선명도)을 Python OpenCV로 똑같이 옮겨 검증한다."""
import math
import cv2
import numpy as np


def page(angle=0.0, glare=False, blur=False, color_paper=(215, 215, 215)):
    img = np.full((1200, 900, 3), color_paper, np.uint8)
    for i in range(18):
        cv2.putText(img, f'The quick brown fox jumps over line {i}', (60, 90 + i * 60),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.9, (30, 30, 30), 2)
    if glare:
        overlay = img.copy()
        cv2.circle(overlay, (600, 400), 120, (255, 255, 255), -1)
        img = cv2.addWeighted(overlay, 0.97, img, 0.03, 0)
        img = cv2.GaussianBlur(img, (3, 3), 0) if False else img
    out = img
    if angle:
        M = cv2.getRotationMatrix2D((450, 600), angle, 1)
        out = cv2.warpAffine(img, M, (900, 1200), borderMode=cv2.BORDER_REPLICATE)
    if blur:
        out = cv2.GaussianBlur(out, (21, 21), 0)
    return out


def inpaint_glare(img):
    h, w = img.shape[:2]
    s = min(1.0, 1000 / max(w, h))
    small = cv2.resize(img, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA) if s < 1 else img
    sh, sw = small.shape[:2]
    sn = sw * sh
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    hist = np.bincount(gray.ravel(), minlength=256)
    acc, paper = 0, 200
    for v in range(256):
        acc += hist[v]
        if acc >= sn * 0.6:
            paper = v
            break
    thr = max(paper + 28, 232)
    if thr >= 255:
        return img, 0
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    m = ((gray >= thr) & (hsv[..., 1] < 60)).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    cnt, lab, stats, _ = cv2.connectedComponentsWithStats(m, connectivity=8)
    keep = np.zeros(cnt, bool)
    for i in range(1, cnt):
        a = stats[i, 4]
        if sn * 0.0006 < a < sn * 0.5:
            keep[i] = True
    if not keep.any():
        return img, 0
    mm = (keep[lab] * 255).astype(np.uint8)
    covered = int((mm > 0).sum())
    glare = cv2.dilate(mm, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
    valid = (255 - glare).astype(np.float32) / 255
    k = max(31, round(min(sw, sh) / 5) | 1)
    eps = 0.02
    paperC = cv2.mean(small, mask=(255 - glare))
    den = cv2.blur(valid, (k, k)) + eps
    ch = []
    for c in range(3):
        num = cv2.blur(small[..., c].astype(np.float32) * valid, (k, k))
        ch.append(np.clip((num + paperC[c] * eps) / den, 0, 255).astype(np.uint8))
    filled = cv2.merge(ch)
    up = cv2.resize(filled, (w, h), interpolation=cv2.INTER_CUBIC) if s < 1 else filled
    um = cv2.resize(glare, (w, h), interpolation=cv2.INTER_NEAREST) if s < 1 else glare
    out = img.copy()
    o = img.astype(int).sum(2)
    f = up.astype(int).sum(2)
    repl = (um > 0) & (o + 75 >= f)
    out[repl] = up[repl]
    return out, covered / sn


def deskew(img):
    h, w = img.shape[:2]
    s = min(1.0, 700 / max(w, h))
    small = cv2.resize(img, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA) if s < 1 else img
    gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (3, 3), 0)
    _, ink = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
    ink = cv2.dilate(ink, cv2.getStructuringElement(cv2.MORPH_RECT, (15, 1)))
    sh, sw = ink.shape
    c = (sw / 2, sh / 2)

    def score(a):
        r = cv2.warpAffine(ink, cv2.getRotationMatrix2D(c, a, 1), (sw, sh))
        rows = (r > 0).sum(1).astype(float)
        return float((rows * rows).sum())

    base = score(0)
    if base == 0:
        return img, 0.0
    best, bs = 0.0, base
    a = -6.0
    while a <= 6.0 + 1e-9:
        sc = score(a)
        if sc > bs:
            best, bs = a, sc
        a += 0.5
    a = best - 0.4
    while a <= best + 0.4 + 1e-9:
        sc = score(a)
        if sc > bs:
            best, bs = a, sc
        a += 0.1
    if abs(best) < 0.3 or bs < base * 1.03:
        return img, 0.0
    M = cv2.getRotationMatrix2D((w / 2, h / 2), best, 1)
    return cv2.warpAffine(img, M, (w, h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE), best


def sharpness(img):
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    s = 800 / max(g.shape)
    if s < 1:
        g = cv2.resize(g, (round(g.shape[1] * s), round(g.shape[0] * s)), interpolation=cv2.INTER_AREA)
    mean, std = cv2.meanStdDev(g)
    if std[0, 0] < 20 or mean[0, 0] < 1:
        return -1
    lap = cv2.Laplacian(g, cv2.CV_64F)
    _, sd = cv2.meanStdDev(lap)
    return sd[0, 0] ** 2


# 1) 기울기
for ang in (3, -2, 5):
    _, a = deskew(page(angle=ang))
    print(f'deskew: 넣은 기울기 {ang}° -> 보정 {a:.1f}°')
_, a = deskew(page())
print('deskew: 반듯한 페이지 -> ', a)

# 2) 빛 반사
for name, kw in {'반사 있음': dict(glare=True), '반사 없음': dict()}.items():
    src = page(**kw)
    out, r = inpaint_glare(src)
    print(f'glare [{name}] 비율={r:.4f} 중앙 밝기 전 {src[400, 600].tolist()} -> 후 {out[400, 600].tolist()}')
    if name == '반사 있음':
        cv2.imwrite('glare_before.png', src)
        cv2.imwrite('glare_after.png', out)
        # 글씨가 보존되는지: 어두운 픽셀 수 비교
        print('   어두운(글씨) 픽셀 수 전/후:', int((src.sum(2) < 200).sum()), int((out.sum(2) < 200).sum()))
# 하얀 종이 + 반사 없는 경우 오탐 확인
white = page(color_paper=(250, 250, 250))
print('glare [하얀 종이] 비율=', inpaint_glare(white)[1])
# 3) 선명도
print('sharpness 선명:', round(sharpness(page()), 1), ' 흐림:', round(sharpness(page(blur=True)), 1),
      ' 빈 페이지:', sharpness(np.full((1200, 900, 3), 220, np.uint8)))
