"""One reel from tools/track's comparison videos, with a title card before each clip.

  reel.py <ci-track dir> <out.mp4> <label> [--before LABEL] [--speed S] [--loops N] clip:"Title|Subtitle" [clip:"..."]...

<label> picks which run's videos (lensi@8 -> <clip>-compare.mp4, lensi@4 ->
<clip>-lensi-at4-compare.mp4), and --before which one they're compared with (fixed, the
default, or coast@8 -> <clip>-vs-coast-at8-compare.mp4). Clips play at `speed` (1: as
filmed; 0.5 shows each 24 fps frame twice, which looks choppier than the footage is)
`loops` times. Needs ffmpeg.
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

W, H = 854, 960  # the comparison videos: two 854x480 panels stacked


def font(size, bold=False):
    names = ["DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"]
    for d in ("/usr/share/fonts/truetype/dejavu", "/System/Library/Fonts"):
        for n in names + ["SFNS.ttf", "Helvetica.ttc"]:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def card(path, lines):
    """A plain title card: big first line, the rest smaller."""
    img = Image.new("RGB", (W, H), (14, 14, 16))
    d = ImageDraw.Draw(img)
    y = 300
    for i, text in enumerate(lines):
        f = font(38 if i == 0 else 24, bold=i == 0)
        for line in wrap(d, text, f, W - 100):
            d.text((50, y), line, font=f, fill=(255, 255, 255) if i == 0 else (200, 200, 205))
            y += int(f.size * 1.35)
        y += 18
    img.save(path)


def wrap(d, text, f, width):
    words, line, out = text.split(), "", []
    for w in words:
        t = (line + " " + w).strip()
        if d.textlength(t, font=f) > width and line:
            out.append(line)
            line = w
        else:
            line = t
    if line:
        out.append(line)
    return out


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    src, out, label = sys.argv[1:4]
    rest = sys.argv[4:]
    speed, loops, before = 1.0, 1, "fixed"
    while rest and rest[0].startswith("--"):
        if rest[0] == "--speed":
            speed = float(rest[1])
        elif rest[0] == "--loops":
            loops = int(rest[1])
        elif rest[0] == "--before":
            before = rest[1]
        rest = rest[2:]
    tag = "" if label == "lensi@8" else "-" + label.replace("@", "-at")
    vs = "" if before == "fixed" else "-vs-" + before.replace("@", "-at")
    how = {"lensi@8": "SAM 8 times a second; in between, the points inside the outline are followed frame to frame",
           "lensi@4": "SAM 4 times a second; in between, the points inside the outline are followed frame to frame",
           "coast@8": "SAM 8 times a second; in between, the outline coasts at its last speed"}.get(label, label)
    was = {"fixed": "SAM asked at the same spot every frame",
           "coast@8": "SAM 8 times a second, coasting between cuts: the last reel"}.get(before, before)
    tmp = tempfile.mkdtemp()
    parts = []
    for n, arg in enumerate(rest):
        clip, titles = arg.split(":", 1)
        title, sub = (titles.split("|", 1) + [""])[:2]
        stats = json.load(open(os.path.join(src, f"{clip}.json")))
        runs = {r["label"]: r for r in stats["runs"]}
        j_now, j_old = runs[label]["J"], runs[before]["J"]
        score = (f"On the thing (overlap with the hand-drawn mask): before {j_old * 100:.0f}%, now {j_now * 100:.0f}%"
                 if j_now >= 0 else "No hand-drawn mask for this clip: judge by eye.")
        k_now, k_old, k_true = runs[label].get("jerk", -1), runs[before].get("jerk", -1), stats.get("truthJerk", -1)
        if k_now >= 0 and k_old >= 0:
            own = f" (the hand-drawn outline's own: {k_true:.1f} px)" if k_true >= 0 else ""
            score += f". Lurch from frame to frame: before {k_old:.1f} px, now {k_now:.1f} px{own}"
        png = os.path.join(tmp, f"card{n}.png")
        pace = "As filmed." if speed == 1 else f"{speed:g}x speed."
        card(png, [title, sub, score, f"Top: before ({was}). Bottom: now ({how}). {pace}"])
        c = os.path.join(tmp, f"c{n}.mp4")
        run("ffmpeg", "-y", "-loop", "1", "-t", "3.2", "-i", png, "-vf", "fps=30,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", c)
        v = os.path.join(tmp, f"v{n}.mp4")
        run("ffmpeg", "-y", "-stream_loop", str(loops - 1), "-i", os.path.join(src, f"{clip}{tag}{vs}-compare.mp4"),
            "-vf", f"setpts={1 / speed:g}*PTS,scale={W}:{H},fps=30,format=yuv420p", "-an",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", v)
        parts += [c, v]
    lst = os.path.join(tmp, "list.txt")
    with open(lst, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    run("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", "-movflags", "+faststart", out)
    print("wrote", out)


if __name__ == "__main__":
    main()
