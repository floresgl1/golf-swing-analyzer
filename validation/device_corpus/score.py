"""Score the phase detectors against hand-placed labels (P1.4).

This is the measurement P1.4 has been blocked on. `locate_swing()` is
demonstrably better than `detect_phases()` on real clips — it puts the
events inside the swing instead of at frame 1 — but "better" was read off
plots by eye, and its answer moves six seconds when DESCENT_SMOOTH_S moves
from 0.05 to 0.10. Eye-judgement cannot tell those two apart. Labels can.

Two questions, in order of how much they matter:

  1. CONTAINMENT — do the detector's top and impact land inside the swing
     at all? This is the P1.3 question, and on unlabelled data the honest
     answer was "no, all eight anchored in the walk-in". It needs only a
     rough window, so a label with just top_s and impact_s still answers it.
  2. OFFSET — how far off is each event? Reported in seconds AND in frames,
     because a frame count means different things at 30 and 240 fps.

Reports per-swing rows and a summary. Deliberately does NOT compute a
single headline score: with a handful of labelled swings, a mean offset
would invite a precision the sample cannot support.

  python validation/device_corpus/score.py
  python validation/device_corpus/score.py --labels path/to/labels.json
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "src"))

from swing_phases import detect_phases  # noqa: E402

LABELS = REPO / "validation" / "device_corpus" / "labels.json"
CORPORA = sorted((REPO / "tests" / "fixtures").glob("device_corpus_*.jsonl"))
EVENTS = ("takeaway", "top", "impact", "finish")


def load_records(paths: list[Path]) -> dict[str, dict]:
    """Every swing record, keyed by timestamp."""
    records = {}
    for path in paths:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            if record.get("record") == "header":
                continue
            records[record["timestamp"]] = record
    return records


def labelled_frames(entry: dict, fps: float) -> dict[str, int | None]:
    """The label's four events as frame indices, or None where unlabelled."""
    frames = {}
    for event in EVENTS:
        seconds = entry.get(f"{event}_s")
        frames[event] = None if seconds is None else int(round(seconds * fps))
    return frames


def detector_results(record: dict) -> dict[str, dict | None]:
    """Both localizations for one record.

    `locate_swing` is reached by passing `torso=`, which is how it stays
    opt-in and out of the app's path.
    """
    wrist = np.array(record["frames"]["wrist_y"], dtype=float)
    torso = np.array(record["frames"]["torso"], dtype=float)
    fps = float(record["fps"])
    return {
        "detect_phases": detect_phases(wrist, fps=fps),
        "locate_swing": detect_phases(wrist, fps=fps, torso=torso),
    }


def score_swing(entry: dict, record: dict) -> dict:
    fps = float(record["fps"])
    truth = labelled_frames(entry, fps)
    results = detector_results(record)

    # The swing's extent, for the containment question. Falls back to
    # top..impact when the outer events were not called — a labeller who
    # could only find the top and the strike has still answered question 1.
    lo = truth["takeaway"] if truth["takeaway"] is not None else truth["top"]
    hi = truth["finish"] if truth["finish"] is not None else truth["impact"]

    scored = {"timestamp": entry["timestamp"], "fps": fps, "detectors": {}}
    for name, result in results.items():
        if result is None:
            scored["detectors"][name] = None
            continue
        offsets = {}
        for event in EVENTS:
            if truth[event] is None:
                offsets[event] = None
            else:
                offsets[event] = result[event] - truth[event]
        inside = None
        if lo is not None and hi is not None:
            inside = all(lo <= result[e] <= hi for e in ("top", "impact"))
        scored["detectors"][name] = {
            "events": {e: result[e] for e in EVENTS},
            "offsets": offsets,
            "inside_swing": inside,
        }
    return scored


def print_report(scored: list[dict]) -> None:
    for swing in scored:
        fps = swing["fps"]
        print(f"\n{swing['timestamp']}  @ {fps:.2f} fps")
        for name, result in swing["detectors"].items():
            if result is None:
                print(f"  {name:<16} returned nothing")
                continue
            inside = result["inside_swing"]
            verdict = {True: "INSIDE the swing",
                       False: "OUTSIDE the swing",
                       None: "containment unlabelled"}[inside]
            print(f"  {name:<16} {verdict}")
            for event in EVENTS:
                frame = result["events"][event]
                offset = result["offsets"][event]
                if offset is None:
                    print(f"      {event:<9} {frame:>5}f  {frame / fps:6.2f}s"
                          f"   (unlabelled)")
                else:
                    print(f"      {event:<9} {frame:>5}f  {frame / fps:6.2f}s"
                          f"   off by {offset:+5d}f / {offset / fps:+6.2f}s")

    print("\n" + "=" * 60)
    for name in ("detect_phases", "locate_swing"):
        judged = [s["detectors"][name] for s in scored
                  if s["detectors"].get(name)
                  and s["detectors"][name]["inside_swing"] is not None]
        if not judged:
            print(f"{name:<16} nothing labelled well enough to judge")
            continue
        inside = sum(1 for r in judged if r["inside_swing"])
        print(f"{name:<16} top and impact inside the swing on "
              f"{inside}/{len(judged)} labelled swings")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--labels", type=Path, default=LABELS)
    parser.add_argument("--corpus", type=Path, nargs="+", default=CORPORA)
    args = parser.parse_args()

    labels = json.loads(args.labels.read_text())
    records = load_records(args.corpus)

    scored = []
    unlabelled = 0
    for entry in labels["swings"]:
        if all(entry.get(f"{e}_s") is None for e in EVENTS):
            unlabelled += 1
            continue
        record = records.get(entry["timestamp"])
        if record is None:
            print(f"warning: no record for {entry['timestamp']}; skipping")
            continue
        scored.append(score_swing(entry, record))

    if not scored:
        print(f"No labelled swings yet ({unlabelled} awaiting labels).")
        print(f"Fill in the *_s fields in {args.labels.relative_to(REPO)} "
              "and run again.")
        return

    print_report(scored)
    if unlabelled:
        print(f"\n({unlabelled} swing(s) still unlabelled.)")


if __name__ == "__main__":
    main()
