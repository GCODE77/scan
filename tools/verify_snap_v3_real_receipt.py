import cv2, numpy as np, sys
sys.path.insert(0, '.')
from snap_edge_v3 import snap_edge_v3
img = cv2.imread('photo_undim.png')
H_, W_ = img.shape[:2]
k = 1.17
P = lambda x, y: ((x - 45) * k, (y - 378) * k)
TL, TR, BR, BL = P(156, 458), P(747, 490), P(775, 1368), P(183, 1347)
quad = [TL, TR, BR, BL]
line = lambda a, b, n=5: [(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t) for t in np.linspace(0.1667, 0.8333, n)]
vis = img.copy()
for name, edge, a, b in [('위', 0, TL, TR), ('오른쪽', 1, TR, BR), ('아래', 2, BR, BL), ('왼쪽', 3, BL, TL)]:
    pts = line(a, b, 5 if edge in (0, 2) else 3)
    res, offs = snap_edge_v3(img, quad, edge, pts, verbose=True)
    print(name, '이동(px):', [round(float(np.hypot(r[0]-p[0], r[1]-p[1])), 1) for p, r in zip(pts, res)])
    for p, r in zip(pts, res):
        cv2.circle(vis, (int(p[0]), int(p[1])), 6, (0, 255, 255), 2)
        cv2.circle(vis, (int(r[0]), int(r[1])), 6, (0, 0, 255), -1)
cv2.imwrite('real_v3.png', vis)
