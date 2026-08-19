"""Render a label sheet for the device corpus: one plot per recording.

P1.4 is blocked on ground truth -- somebody has to say where the swing
actually is in each clip -- and the obvious way to get that (rewatch the
video, scrub to the top of the backswing) is NOT available for the five
recordings in tests/fixtures/device_corpus_2026_08_17.jsonl:

  * record_screen.dart hands stopVideoRecording()'s path straight to the
    analyzer and keeps no copy,
  * nothing writes the video into the app's Documents directory, so the
    UIFileSharingEnabled route added for the corpus export cannot see it,
  * and the file sits in the app's temp directory, which iOS reclaims.

The clips are gone. The per-frame series they produced are not: the corpus
carries eye/shoulder/hip/wrist tracks for every frame, which is enough to
SEE the swing -- the walk-in wanders, the address holds still, the swing is
the one violent excursion. That is what this renders.

Read a sheet, find the swing, and write the frame numbers into
labels.json (see --write-template) as ground truth for P1.4.

  python validation/device_corpus/label_sheet.py
  python validation/device_corpus/label_sheet.py --write-template

Deliberately NOT here: any automatic guess at the swing location overlaid
on the plot. locate_swing() is the thing these labels exist to judge, and
drawing its answer on the sheet the human labels from would contaminate
the ground truth with the hypothesis.
"""
import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / "tests" / "fixtures" / "device_corpus_2026_08_17.jsonl"
OUT_DIR = REPO / "validation" / "device_corpus" / "sheets"
LABELS = REPO / "validation" / "device_corpus" / "labels.json"


def load_swings(path: Path) -> list[dict]:
    """Every non-header record, in file order."""
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        if record.get("record") == "header":
            continue
        records.append(record)
    return records


def render(index: int, swing: dict, out_dir: Path) -> Path:
    """One sheet: the whole clip, twice, plus what was actually tracked."""
    frames = swing["frames"]
    wrist_y = np.array(frames["wrist_y"], dtype=float)
    hip_y = np.array(frames["hip_y"], dtype=float)
    shoulder_y = np.array(frames["shoulder_y"], dtype=float)
    torso = np.array(frames["torso"], dtype=float)
    fps = float(swing["fps"])
    n = len(wrist_y)
    t = np.arange(n) / fps

    fig, (ax_px, ax_norm, ax_gaps) = plt.subplots(
        3, 1, figsize=(14, 8), sharex=True,
        gridspec_kw={"height_ratios": [3, 3, 1]},
    )

    # --- Panel 1: raw pixels, axis inverted so up on the plot is up in the
    # world. Not "1 - y": these series are IMAGE COORDINATES, not the
    # normalized 0..1 the detectors were prototyped on, and subtracting
    # them from 1 produces a number whose only honest reading is "flipped".
    ax_px.plot(t, wrist_y, lw=1.2, color="#1f4e79", label="lead wrist")
    ax_px.plot(t, shoulder_y, lw=0.8, color="#999999", label="shoulder")
    ax_px.plot(t, hip_y, lw=0.8, color="#cccccc", label="hip")
    ax_px.invert_yaxis()
    # Pose failures produce landmarks thousands of pixels off-frame, which
    # would otherwise flatten the swing into the thickness of the line.
    _clip_to_body(ax_px, np.concatenate([wrist_y, shoulder_y, hip_y]))
    ax_px.set_ylabel("image y (px)\nup = up")
    ax_px.legend(loc="upper right", fontsize=8)
    ax_px.grid(alpha=0.3)
    ax_px.set_title(
        f"swing {index}  --  {swing['timestamp']}  --  "
        f"{n} frames @ {fps:.2f}fps ({n / fps:.1f}s)  --  "
        f"pose_coverage {swing['pose_coverage']:.2f}"
    )

    top = ax_px.secondary_xaxis(
        "top", functions=(lambda s: s * fps, lambda f: f / fps)
    )
    top.set_xlabel("frame")

    # --- Panel 2: wrist height above the hips in torso lengths. The golfer
    # walks toward and away from a fixed camera, so their pixel scale
    # changes over the clip; this removes that, and removes camera
    # placement with it. Purely a change of units -- it makes no claim
    # about where the swing is.
    with np.errstate(invalid="ignore", divide="ignore"):
        above_hip = (hip_y - wrist_y) / torso
    above_hip[~np.isfinite(above_hip)] = np.nan
    ax_norm.plot(t, above_hip, lw=1.2, color="#7a4e1f")
    ax_norm.axhline(0, color="#999999", lw=0.8)
    ax_norm.set_ylim(-2.0, 2.5)
    ax_norm.set_ylabel("wrist above hip\n(torso lengths)")
    ax_norm.grid(alpha=0.3)

    # --- Panel 3: where the pose was lost. This matters to a labeller: a
    # missing stretch is interpolated by the detectors, so its shape is
    # invented and must not be labelled as a swing.
    tracked = np.isfinite(wrist_y).astype(float)
    ax_gaps.fill_between(t, 0, tracked, step="mid", color="#4c9a2a", lw=0)
    ax_gaps.set_ylim(0, 1)
    ax_gaps.set_yticks([])
    ax_gaps.set_ylabel("pose", rotation=0, ha="right", va="center")
    ax_gaps.set_xlabel("seconds")
    ax_gaps.grid(axis="x", alpha=0.3)

    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"swing_{index}.png"
    fig.tight_layout()
    fig.savefig(out, dpi=110)
    plt.close(fig)
    return out


def _clip_to_body(ax, values: np.ndarray) -> None:
    """Limit the y-axis to where the body actually is, with margin."""
    good = values[np.isfinite(values)]
    if good.size == 0:
        return
    lo, hi = np.percentile(good, [2, 98])
    margin = 0.15 * max(hi - lo, 1.0)
    # The axis is inverted, so the limits go high-to-low.
    ax.set_ylim(hi + margin, lo - margin)


def write_template(swings: list[dict], path: Path) -> None:
    """A labels.json with the slots empty, so filling it in is the only work."""
    template = {
        "source": str(CORPUS.relative_to(REPO)),
        "note": (
            "Frame indices into frames.* of the corresponding record. "
            "null means 'not visible / cannot tell' -- leave it null rather "
            "than guessing; a guessed label is worse than a missing one."
        ),
        "swings": [
            {
                "index": i,
                "timestamp": s["timestamp"],
                "frame_count": s["frame_count"],
                "fps": s["fps"],
                "takeaway": None,
                "top": None,
                "impact": None,
                "finish": None,
            }
            for i, s in enumerate(swings)
        ],
    }
    path.write_text(json.dumps(template, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    parser.add_argument("--out", type=Path, default=OUT_DIR)
    parser.add_argument(
        "--write-template",
        action="store_true",
        help="also write an empty labels.json next to the sheets",
    )
    args = parser.parse_args()

    swings = load_swings(args.corpus)
    for i, swing in enumerate(swings):
        out = render(i, swing, args.out)
        print(f"swing {i}: {swing['frame_count']} frames -> {out}")

    if args.write_template:
        if LABELS.exists():
            print(f"{LABELS} exists; not overwriting")
        else:
            write_template(swings, LABELS)
            print(f"wrote {LABELS}")


if __name__ == "__main__":
    main()
