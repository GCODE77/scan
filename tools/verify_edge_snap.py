"""snapEdgePoints(자석 올가미)를 Python OpenCV로 옮겨, 곡선 변이 있는 합성 사진에서 검증한다."""
import math
import cv2
import numpy as np

W, H = 1600, 1200


def make_photo(seed=0, desk=(70, 90, 110), paper=(225, 228, 232), tile=False):
    rng = np.random.default_rng(seed)
    img = np.full((H, W, 3), desk, np.uint8)
    if tile:  # 바닥 타일 줄눈
        for x in range(0, W, 160):
            cv2.line(img, (x, 0), (x, H), (40, 50, 60), 3)
        for y in range(0, H, 160):
            cv2.line(img, (0, y), (W, y), (40, 50, 60), 3)
    # 종이: 위 변이 아래로 볼록(곡선), 나머지는 직선
    tl, tr, br, bl = (260, 200), (1340, 230), (1300, 1050), (300, 1020)
    top = [(tl[0] + (tr[0] - tl[0]) * t, tl[1] + (tr[1] - tl[1]) * t - 60 * 4 * t * (1 - t)) for t in np.linspace(0, 1, 60)]
    poly = np.array(top + [br, bl], np.int32)
    cv2.fillPoly(img, [poly], paper)
    for i in range(14):
        cv2.putText(img, f'Sample text line number {i} for testing', (340, 330 + i * 50),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (40, 40, 40), 2)
    noise = rng.normal(0, 3, img.shape)
    img = np.clip(img + noise, 0, 255).astype(np.uint8)
    return img, top, (tl, tr, br, bl)


def paper_model(lab, q):
    center = np.mean(q, 0)
    inner = []
    for i in range(21):
        for j in range(21):
            tp = np.array(q[0]) + (np.array(q[1]) - np.array(q[0])) * i / 20
            bt = np.array(q[3]) + (np.array(q[2]) - np.array(q[3])) * j / 20 * 0 + (np.array(q[2]) - np.array(q[3])) * i / 20
            pt = tp + (bt - tp) * j / 20
            inner.append(center + (pt - center) * 0.6)
    px = []
    for p in inner:
        x, y = int(round(p[0])), int(round(p[1]))
        if 0 <= x < W and 0 <= y < H:
            px.append(lab[y, x].astype(float))
    px = np.array(px)
    px = px[np.argsort(px[:, 0])]
    bright = px[len(px) // 2:]
    pc = np.median(bright, 0)
    d = np.sort(np.sqrt(((bright[:, 0] - pc[0]) * 0.5) ** 2 + (bright[:, 1] - pc[1]) ** 2 + (bright[:, 2] - pc[2]) ** 2))
    dlim = max(12.0, d[int(len(d) * 0.75)] * 1.3)

    def paperness(p):
        x, y = int(round(p[0])), int(round(p[1]))
        if x < 0 or y < 0 or x >= W or y >= H:
            return -255.0
        l = lab[y, x].astype(float)
        return -math.sqrt(((l[0] - pc[0]) * 0.5) ** 2 + (l[1] - pc[1]) ** 2 + (l[2] - pc[2]) ** 2)

    return paperness, -dlim, 15, 20


def snap_edge_points(img, quad, edge, pts):
    lab = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2Lab), (5, 5), 0)
    q = [np.array(p, float) for p in quad]
    center = np.mean(q, 0)
    diag = (np.linalg.norm(q[2] - q[0]) + np.linalg.norm(q[3] - q[1])) / 2
    a, b = q[edge], q[(edge + 1) % 4]
    d = b - a
    n = np.array([-d[1], d[0]]) / np.linalg.norm(d)
    if np.dot(center - (a + b) / 2, n) > 0:
        n = -n
    band = max(10, round(diag * 0.07))
    paperness, inT, gap, minDiff = paper_model(lab, q)
    offs = []
    for p in pts:
        prof = [paperness(np.array(p) + n * j) for j in range(-band - 8, band + 9)]
        best, bs = None, -1e9
        for i in range(8, len(prof) - 8):
            inside = np.mean(prof[i - 7:i - 2])
            outside = np.mean(prof[i + 2:i + 7])
            if inside > inT and outside < inT - gap and inside - outside > minDiff:
                off = i - band - 8
                sc = (inside - outside) - 0.5 * abs(off)
                if sc > bs:
                    bs, best = sc, off
        offs.append(best)
    found = [o for o in offs if o is not None]
    if len(found) < len(pts) * 0.6:
        return pts, offs
    med = sorted(found)[len(found) // 2]
    good, res = 0, []
    for p, o in zip(pts, offs):
        if o is None or abs(o - med) > band * 0.5:
            o = med
        else:
            good += 1
        res.append(tuple(np.array(p) + n * o))
    if good < len(pts) * 0.5:
        return pts, offs
    return res, offs


def true_y(top, x):
    xs = [p[0] for p in top]
    return float(np.interp(x, xs, [p[1] for p in top]))


for name, kw in {'책상 위 종이': dict(), '타일 바닥 위 종이': dict(tile=True),
                 '색 종이(노랑)': dict(paper=(150, 220, 235)), '밝은 바닥+흰 종이': dict(desk=(170, 175, 180), paper=(240, 240, 240))}.items():
    img, top, quad = make_photo(**kw)
    q = [quad[0], quad[1], quad[2], quad[3]]
    # 위 변에 놓인 점 5개를 사용자가 '대충' 찍은 상태 (직선 위: 곡선 실제 경계와 어긋남)
    errs_before, errs_after = [], []
    pts = []
    for t in (1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6):
        x = q[0][0] + (q[1][0] - q[0][0]) * t
        y = q[0][1] + (q[1][1] - q[0][1]) * t
        pts.append((x, y))
    res, offs = snap_edge_points(img, q, 0, pts)
    for p, r in zip(pts, res):
        errs_before.append(abs(p[1] - true_y(top, p[0])))
        errs_after.append(abs(r[1] - true_y(top, r[0])))
    print(f'[{name}] 평균 오차 전 {np.mean(errs_before):.1f}px -> 후 {np.mean(errs_after):.1f}px | 찾은 점 {sum(o is not None for o in offs)}/5')
