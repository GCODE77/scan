"""변 자석 v3: Lab 색차 + 경계 뒤가 계속 다른 색(글자 줄 배제) + 가장 바깥쪽의 뚜렷한 경계 + 곡선 맞춤."""
import math
import cv2
import numpy as np

W_L = 0.5  # 밝기 차는 그림자 때문에 절반만 반영


def de(a, b):
    d = np.asarray(a, float) - np.asarray(b, float)
    return math.sqrt((d[0] * W_L) ** 2 + d[1] ** 2 + d[2] ** 2)


def snap_edge_v3(img, quad, edge, pts, verbose=False):
    h, w = img.shape[:2]
    lab = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2Lab), (5, 5), 0).astype(np.float32)
    q = [np.array(p, float) for p in quad]
    center = np.mean(q, 0)
    diag = (np.linalg.norm(q[2] - q[0]) + np.linalg.norm(q[3] - q[1])) / 2
    a, b = q[edge], q[(edge + 1) % 4]
    d = b - a
    ln = np.linalg.norm(d)
    t = d / ln
    n = np.array([-t[1], t[0]])
    if np.dot(center - (a + b) / 2, n) > 0:
        n = -n
    band = max(10, round(diag * 0.07))

    # 종이 색: 사각형 안쪽(가운데 60%)에서 밝은 쪽 절반의 중앙값
    samp = []
    for i in range(21):
        for j in range(21):
            tp = q[0] + (q[1] - q[0]) * i / 20
            bt = q[3] + (q[2] - q[3]) * i / 20
            p = center + (tp + (bt - tp) * j / 20 - center) * 0.6
            x, y = int(round(p[0])), int(round(p[1]))
            if 0 <= x < w and 0 <= y < h:
                samp.append(lab[y, x])
    samp = np.array(samp)
    samp = samp[np.argsort(samp[:, 0])][len(samp) // 2:]
    paper = np.median(samp, 0)

    def at(p):
        x, y = int(round(p[0])), int(round(p[1]))
        return lab[y, x] if 0 <= x < w and 0 <= y < h else np.array([0, 128, 128], np.float32)

    offs_all = []
    for p0 in pts:
        p0 = np.array(p0, float)
        js = range(-band - 10, band + 11)
        prof = np.array([np.mean([at(p0 + n * j + t * s) for s in (-10, 0, 10)], 0) for j in js])
        m = len(prof)
        cands = []
        for i in range(10, m - 10):
            inside = prof[i - 9:i - 1].mean(0)
            outside = prof[i + 2:i + 10].mean(0)
            s = de(inside, outside)
            if s < 7 or de(inside, paper) > 22:
                continue
            tail = prof[i + 3:min(m, i + 28)]
            far = np.mean([de(x, inside) >= 0.5 * s for x in tail])
            if far < 0.8:  # 경계 뒤에 종이가 다시 나오면 글자 줄·접힌 선
                continue
            cands.append((i - band - 10, s))
        loc = [(o, s) for (o, s) in cands if all(s >= s2 for (o2, s2) in cands if abs(o2 - o) <= 6)]
        if not loc:
            offs_all.append(None)
            continue
        smax = max(s for _, s in loc)
        strong = [(o, s) for o, s in loc if s >= 0.45 * smax]
        offs_all.append(max(strong, key=lambda c: c[0])[0])
    found = [(i, o) for i, o in enumerate(offs_all) if o is not None]
    if verbose:
        print('   raw', offs_all)
    if len(found) < len(pts) * 0.6:
        return list(pts), offs_all
    xs = np.array([i / (len(pts) - 1) for i, _ in found])
    vs = np.array([o for _, o in found], float)
    import itertools
    # 1) 곡선(이차): 점이 충분하고 거의 모두(4/5) 6px 안에서 한 포물선에 놓일 때만 쓴다 (휜 변)
    tolq = max(5.0, band * 0.06)
    c = None
    if len(found) >= 4:
        best_in = []
        for comb in itertools.combinations(range(len(found)), 3):
            cc = np.polyfit(xs[list(comb)], vs[list(comb)], 2)
            # 종이 변이 휠 수 있는 한계: 양 끝을 잇는 선에서 가운데가 변 길이의 8% 넘게 벗어나면 말이 안 된다
            bow = abs(np.polyval(cc, 0.5) - (np.polyval(cc, 0.0) + np.polyval(cc, 1.0)) / 2)
            if bow > 0.08 * ln:
                continue
            inl = [i for i in range(len(found)) if abs(vs[i] - np.polyval(cc, xs[i])) <= tolq]
            if len(inl) > len(best_in):
                best_in = inl
        if len(best_in) >= max(4, math.ceil(len(pts) * 0.8)):
            c = np.polyfit(xs[best_in], vs[best_in], 2)
            if verbose:
                print('   quad inliers', best_in)
    # 2) 직선(기울기 허용, 점이 3개 이하면 상수): 가장 많은 점이 맞는 것
    if c is None:
        tol = max(7.0, band * 0.12)
        k = 2 if len(found) >= 4 else 1
        best_in = []
        for comb in itertools.combinations(range(len(found)), k):
            cc = np.polyfit(xs[list(comb)], vs[list(comb)], 1) if k == 2 else np.array([vs[comb[0]]])
            res = np.abs(vs - np.polyval(cc, xs))
            inl = [i for i in range(len(found)) if res[i] <= tol]
            if len(inl) > len(best_in):
                best_in = inl
        if len(best_in) < max(2, math.ceil(len(pts) * 0.5)):
            return list(pts), offs_all  # 일관된 경계를 못 찾으면 손대지 않는다
        c = np.polyfit(xs[best_in], vs[best_in], 1) if (k == 2 and len(best_in) >= 3) else np.array([np.median(vs[best_in])])
        if verbose:
            print('   line inliers', best_in, 'coef', np.round(c, 1))
    out = [tuple(np.array(p) + n * float(np.polyval(c, i / (len(pts) - 1)))) for i, p in enumerate(pts)]
    return out, offs_all
