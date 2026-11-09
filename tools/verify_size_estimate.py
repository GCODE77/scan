import cv2, numpy as np, math
src = cv2.imread('photo_undim.png')
rng = np.random.default_rng(5)
H, W = src.shape[:2]
pages = []
for i in range(8):
    scale = rng.uniform(1.6, 3.2)                      # 페이지 크기가 제각각 (폰 사진을 편 결과 느낌)
    ch, cw = int(H * rng.uniform(0.55, 0.95)), int(W * rng.uniform(0.6, 0.98))
    y0, x0 = rng.integers(0, H - ch + 1), rng.integers(0, W - cw + 1)
    crop = src[y0:y0 + ch, x0:x0 + cw]
    pg = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    if i % 4 == 3:                                      # 내용이 거의 없는 페이지도 섞는다
        pg = cv2.GaussianBlur(pg, (51, 51), 0)
    pages.append(cv2.imencode('.jpg', pg, [cv2.IMWRITE_JPEG_QUALITY, 92])[1].tobytes())
print('페이지 JPG 크기(KB):', [len(p) // 1024 for p in pages])

def enc(jpg, maxside, q, ext):
    m = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    if maxside:
        s = maxside / max(m.shape[:2])
        if s < 1: m = cv2.resize(m, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    if ext == 'jpg': return len(jpg) if not maxside else len(cv2.imencode('.jpg', m, [cv2.IMWRITE_JPEG_QUALITY, q])[1])
    return len(cv2.imencode('.png', m)[1])

def png_probe(jpg, maxside):                            # probeSizes 의 PNG 어림(큰 사진은 줄여 재고 늘림)
    m = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    if maxside:
        s = maxside / max(m.shape[:2])
        if s < 1: m = cv2.resize(m, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    big = max(m.shape[:2])
    if big <= 1000: return len(cv2.imencode('.png', m)[1])
    s = 1000 / big
    sm = cv2.resize(m, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    return round(len(cv2.imencode('.png', sm)[1]) / (s * s))

order = sorted(range(len(pages)), key=lambda i: len(pages[i]))
sample = pages[order[len(pages) // 2]]
tot_len = sum(len(p) for p in pages)
for name, ms, q in [('고화질', None, 95), ('표준', 2200, 85), ('작게', 1400, 72)]:
    for ext in ('jpg', 'png'):
        actual = sum(enc(p, ms, q, ext) for p in pages)
        one = enc(sample, ms, q, 'jpg') if ext == 'jpg' else png_probe(sample, ms)
        est = one * tot_len / len(sample)
        print(f'{name} {ext}: 실제 {actual/1048576:6.1f} MB | 추정 {est/1048576:6.1f} MB | 오차 {100*(est-actual)/actual:+5.1f}%')

print('--- 개선: 줄인 뒤 픽셀 수 + 내용 복잡도(원본 바이트/픽셀) 기준 ---')
def dims(jpg):
    m = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR); return m.shape[1], m.shape[0]
def pix_out(w, h, ms):
    if not ms: return w * h
    s = ms / max(w, h); s = min(1, s)
    return round(w * s) * round(h * s)
sw, sh = dims(sample); slen = len(sample); spix = sw * sh
for name, ms, q in [('고화질', None, 95), ('표준', 2200, 85), ('작게', 1400, 72)]:
    for ext in ('jpg', 'png'):
        actual = sum(enc(p, ms, q, ext) for p in pages)
        one = enc(sample, ms, q, 'jpg') if ext == 'jpg' else png_probe(sample, ms)
        est = 0
        for p in pages:
            w, h = dims(p)
            est += one * (pix_out(w, h, ms) / pix_out(sw, sh, ms)) * ((len(p) / (w * h)) / (slen / spix))
        print(f'{name} {ext}: 실제 {actual/1048576:6.1f} MB | 추정 {est/1048576:6.1f} MB | 오차 {100*(est-actual)/actual:+5.1f}%')

print('--- PNG: 복잡도 지수 k 시험 (est = 한 장 × 픽셀비 × 복잡도^k) ---')
for k in (1.0, 0.8, 0.6, 0.4, 0.2, 0.0):
    errs = []
    for name, ms, q in [('고화질', None, 95), ('표준', 2200, 85), ('작게', 1400, 72)]:
        actual = sum(enc(p, ms, q, 'png') for p in pages)
        one = png_probe(sample, ms)
        est = 0
        for p in pages:
            w, h = dims(p)
            est += one * (pix_out(w, h, ms) / pix_out(sw, sh, ms)) * (((len(p) / (w * h)) / (slen / spix)) ** k)
        errs.append(100 * (est - actual) / actual)
    print(f'k={k}: 고화질 {errs[0]:+5.1f}%  표준 {errs[1]:+5.1f}%  작게 {errs[2]:+5.1f}%')

print('--- PNG 어림 방식 비교: 원래 해상도 조각 3개(세로 25/50/75%) ---')
def png_probe_crops(jpg, maxside, n=3, sz=480):
    m = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
    if maxside:
        s = maxside / max(m.shape[:2])
        if s < 1: m = cv2.resize(m, None, fx=s, fy=s, interpolation=cv2.INTER_AREA)
    h, w = m.shape[:2]
    cs = min(sz, h, w)
    tot = 0
    for f in (0.25, 0.5, 0.75)[:n]:
        y0 = int(min(max(h * f - cs / 2, 0), h - cs)); x0 = (w - cs) // 2
        tot += len(cv2.imencode('.png', m[y0:y0 + cs, x0:x0 + cs])[1])
    bpp = tot / (n * cs * cs)
    return bpp * h * w                                    # 한 장 전체 PNG 바이트 어림
for n, sz in [(3, 480), (3, 360), (5, 360)]:
    errs = []
    for name, ms, q in [('고화질', None, 95), ('표준', 2200, 85), ('작게', 1400, 72)]:
        actual = sum(enc(p, ms, q, 'png') for p in pages)
        one = png_probe_crops(sample, ms, n, sz)
        est = 0
        for p in pages:
            w, h = dims(p)
            est += one * (pix_out(w, h, ms) / pix_out(sw, sh, ms)) * ((len(p) / (w * h)) / (slen / spix))
        errs.append(100 * (est - actual) / actual)
    print(f'조각 {n}개 x {sz}px: 고화질 {errs[0]:+5.1f}%  표준 {errs[1]:+5.1f}%  작게 {errs[2]:+5.1f}%')
