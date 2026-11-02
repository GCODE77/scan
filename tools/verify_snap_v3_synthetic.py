import sys, numpy as np, cv2
sys.path.insert(0, '.')
src = open('verify_snap.py', encoding='utf-8').read().split("for name, kw in")[0]
exec(src)
from snap_edge_v3 import snap_edge_v3
for name, kw in {'책상 위 종이': dict(), '타일 바닥': dict(tile=True), '색 종이(노랑)': dict(paper=(150, 220, 235)),
                 '밝은 바닥+흰 종이': dict(desk=(170, 175, 180), paper=(240, 240, 240))}.items():
    img, top, quad = make_photo(**kw)
    q = list(quad)
    pts = [(q[0][0] + (q[1][0] - q[0][0]) * t, q[0][1] + (q[1][1] - q[0][1]) * t) for t in (1/6, 2/6, 3/6, 4/6, 5/6)]
    res, offs = snap_edge_v3(img, q, 0, pts)
    eb = np.mean([abs(p[1] - true_y(top, p[0])) for p in pts])
    ea = np.mean([abs(r[1] - true_y(top, r[0])) for r in res])
    print(f'[{name}] 오차 전 {eb:.1f}px -> 후 {ea:.1f}px | 찾은 점 {sum(o is not None for o in offs)}/5')
