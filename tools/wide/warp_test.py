"""UltraWideCamera.warp (app/modules/lensi-ar/ios/UltraWide.swift), ported line for line, against
a pinhole camera turned for real: python3 tools/wide/warp_test.py

A phone held upright: the back camera's picture right is the phone's +x, picture down its -y,
and it looks along -z. The phone turns by a rotation vector `theta` (radians, about its own axes,
what integrating CMDeviceMotion.rotationRate gives). Points fixed in the world, seen before and
after: warp(before) should land on after."""
import numpy as np

def quat(angle, axis):
    axis = axis / np.linalg.norm(axis)
    return np.concatenate([[np.cos(angle / 2)], np.sin(angle / 2) * axis])

def act(q, v):  # rotate v by unit quaternion q (w, x, y, z), as simd_quatf.act
    w, x, y, z = q
    qv = np.array([x, y, z])
    t = 2 * np.cross(qv, v)
    return v + w * t + np.cross(qv, t)

def warp(points, theta, fov, size):  # UltraWide.swift's warp, minus the time bookkeeping
    angle = np.linalg.norm(theta)
    back = quat(-angle, theta / angle)
    W, H = size
    long = max(W, H)
    f = long / 2 / np.tan(fov / 2)
    cx, cy = W / 2, H / 2
    out = []
    for px, py in points:
        x = (px * W - cx) / f
        y = (py * H - cy) / f
        seen = act(back, np.array([x, -y, -1.0]))
        u = cx + f * seen[0] / -seen[2]
        v = cy + f * -seen[1] / -seen[2]
        out.append((u / W, v / H))
    return np.array(out)

def rotvec_to_matrix(r):
    a = np.linalg.norm(r)
    k = r / a
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(a) * K + (1 - np.cos(a)) * K @ K

def project(dirs_phone, fov, size):  # world directions in the phone's frame -> upright picture fractions
    W, H = size
    f = max(W, H) / 2 / np.tan(fov / 2)
    out = []
    for d in dirs_phone:
        if d[2] >= 0: out.append((np.nan, np.nan)); continue
        u = W / 2 + f * d[0] / -d[2]
        v = H / 2 + f * -d[1] / -d[2]
        out.append((u / W, v / H))
    return np.array(out)

rng = np.random.default_rng(0)
size = (1080, 1920)
fov = np.radians(108)  # an ultra-wide's, across the long side
worst = 0
for trial in range(200):
    theta = rng.normal(size=3) * 0.15  # up to ~0.3 rad: a fast flick over a tenth of a second
    # Points in front of the phone before it turns (its own frame then).
    dirs = np.stack([rng.uniform(-0.6, 0.6, 8), rng.uniform(-1.1, 1.1, 8), -np.ones(8)], axis=1)
    before = project(dirs, fov, size)
    # The phone turns by theta (about its own axes): a world-fixed direction's coordinates in the
    # new phone frame are R(theta)^T d.
    R = rotvec_to_matrix(theta)
    after = project((R.T @ dirs.T).T, fov, size)
    ok = ~np.isnan(after).any(axis=1)
    got = warp(before[ok], theta, fov, size)
    err = np.abs(got - after[ok]).max() * 1920
    worst = max(worst, err)
print(f"warp vs a real turn: worst error {worst:.4f} px over 200 random turns")
assert worst < 0.01, "warp disagrees with a real turn"
# CoreMotion's rotation rate is right-handed about the phone's axes: turning left is +y, and
# what's ahead slides right in the picture.
theta = np.array([0.0, 0.1, 0.0])
dirs = np.array([[0.0, 0.0, -1.0]])
print("turn left 0.1 rad about the phone's y: the middle goes to", project((rotvec_to_matrix(theta).T @ dirs.T).T, fov, size)[0], "warp says", warp([(0.5, 0.5)], theta, fov, size)[0])
