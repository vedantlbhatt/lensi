"""One reel from tools/track's comparison videos, with a title card before each clip.

  reel.py <ci-track dir> <out.mp4> <label> [--before LABEL] [--was TEXT] [--how TEXT] [--video SUFFIX]
          [--speed S] [--loops N] clip:"Title|Subtitle" [clip:"..."]...

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


def card(path, blocks):
    """A plain title card: (text, size, bold, grey) blocks top to bottom, the whole stack
    centred on the card. Sized to read on a phone held upright."""
    img = Image.new("RGB", (W, H), (14, 14, 16))
    d = ImageDraw.Draw(img)
    laid = []
    for text, size, bold, grey in blocks:
        f = font(size, bold=bold)
        lines = wrap(d, text, f, W - 100)
        laid.append((f, lines, grey))
    height = sum(len(lines) * int(f.size * 1.3) + 26 for f, lines, _ in laid)
    y = max(40, (H - height) // 2)
    for f, lines, grey in laid:
        for line in lines:
            d.text((50, y), line, font=f, fill=(170, 170, 178) if grey else (255, 255, 255))
            y += int(f.size * 1.3)
        y += 26
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
    speed, loops, before, was_text, how_text, suffix = 1.0, 1, "fixed", None, None, None
    while rest and rest[0].startswith("--"):
        if rest[0] == "--speed":
            speed = float(rest[1])
        elif rest[0] == "--loops":
            loops = int(rest[1])
        elif rest[0] == "--before":
            before = rest[1]
        elif rest[0] == "--was":
            was_text = rest[1]
        elif rest[0] == "--how":
            how_text = rest[1]
        elif rest[0] == "--video":
            suffix = rest[1]  # the comparison video is <clip><suffix>.mp4
        rest = rest[2:]
    tag = "" if label == "lensi@8" else "-" + label.replace("@", "-at")
    vs = "" if before == "fixed" else "-vs-" + before.replace("@", "-at")
    how = {"lensi@8": "SAM 8 times a second; in between, the points inside the outline are followed frame to frame",
           "lensi@4": "SAM 4 times a second; in between, the points inside the outline are followed frame to frame",
           "coast@8": "SAM 8 times a second; in between, the outline coasts at its last speed"}.get(label, label)
    was = {"fixed": "SAM asked at the same spot every frame",
           "coast@8": "SAM 8 times a second, coasting between cuts: the last reel"}.get(before, before)
    how = how_text or how
    was = was_text or was
    tmp = tempfile.mkdtemp()
    parts = []
    for n, arg in enumerate(rest):
        clip, titles = arg.split(":", 1)
        title, sub = (titles.split("|", 1) + [""])[:2]
        stats = json.load(open(os.path.join(src, f"{clip}.json")))
        runs = {r["label"]: r for r in stats["runs"]}
        j_now, j_old = runs[label]["J"], runs[before]["J"]
        k_now, k_old, k_true = runs[label].get("jerk", -1), runs[before].get("jerk", -1), stats.get("truthJerk", -1)
        blocks = [(title, 44, True, False), (sub, 22, False, True)]
        on_now, on_old = runs[label].get("onBox", -1), runs[before].get("onBox", -1)
        if on_now >= 0 and on_old >= 0:
            # tools/pin: how much of the outline is on the thing's hand-drawn 3D box (no SAM in it).
            blocks.append((f"On the thing: {on_old * 100:.0f}% \u2192 {on_now * 100:.0f}%", 36, True, False))
            blocks.append(("Share of the outline on its hand-drawn 3D box, every frame", 22, False, True))
        elif j_now >= 0:
            blocks.append((f"On the thing: {j_old * 100:.0f}% \u2192 {j_now * 100:.0f}%", 36, True, False))
            blocks.append(("Overlap with the outline drawn by hand, every frame", 22, False, True))
        else:
            blocks.append(("No hand-drawn outline for this clip: judge by eye", 26, False, True))
        if k_now >= 0 and k_old >= 0:
            blocks.append((f"Lurch: {k_old:.1f} \u2192 {k_now:.1f} px a frame", 36, True, False))
            own = f"; the thing's own on screen is {k_true:.1f} px" if k_true >= 0 else ""
            blocks.append((f"How far its middle jumps rather than glides{own}", 22, False, True))
        png = os.path.join(tmp, f"card{n}.png")
        pace = "As filmed" if speed == 1 else f"{speed:g}x speed"
        blocks.append((f"Top, white: before ({was}). Bottom, orange: now ({how}). {pace}.", 22, False, True))
        card(png, blocks)
        c = os.path.join(tmp, f"c{n}.mp4")
        run("ffmpeg", "-y", "-loop", "1", "-t", "2.8", "-i", png, "-vf", "fps=30,format=yuv420p",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", c)
        v = os.path.join(tmp, f"v{n}.mp4")
        run("ffmpeg", "-y", "-stream_loop", str(loops - 1), "-i", os.path.join(src, f"{clip}{suffix}.mp4" if suffix else f"{clip}{tag}{vs}-compare.mp4"),
            "-vf", f"setpts={1 / speed:g}*PTS,scale={W}:{H}:force_original_aspect_ratio=decrease,"
                   f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color=0x0e0e10,fps=30,format=yuv420p", "-an",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", v)
        parts += [c, v]
    lst = os.path.join(tmp, "list.txt")
    with open(lst, "w") as f:
        f.writelines(f"file '{p}'\n" for p in parts)
    run("ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", "-movflags", "+faststart", out)
    print("wrote", out)


if __name__ == "__main__":
    main()
