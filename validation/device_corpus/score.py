"""Score the phase detectors against hand-placed labels (P1.4).

This is the measurement P1.4 has been blocked on. `locate_swing()` is
demonstrably better than `detect_phases()` on real clips — it puts the
events inside the swing instead of at frame 1 — but "better" was read off
plots by eye, and its answer moves six seconds when DESCENT_SMOOTH_S moves
from 0.05 to 0.10. Eye-judgement cannot tell those two apart. Labels can.

Labels come at two precisions and both are useful:

  * FOUR EVENTS (`takeaway_s` .. `finish_s`) — full offsets per event.
  * A COARSE START (`swing_start_s`) — roughly when the swing begins, good
    to about a second. This is weaker but it is NOT weak: the errors under
    measurement are seconds wide, so a one-second label still separates a
    detector that finds the swing from one that finds the walk-in, and it
    still separates two settings of DESCENT_SMOOTH_S whose anchors sit six
    seconds apart. Scored against an explicit --window rather than a
    pretended precision.

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


def score_coarse(entry: dict, record: dict, window: float) -> dict:
    """Judge a detector against a rough "the swing starts about here".

    Reports the distance from the labelled start to each detected event, and
    calls the localization consistent when the detected takeaway and top both
    sit within [start - window, start + window]. `window` is a parameter and
    is printed with the result: it is the reader's tolerance, not a fact
    about golf, and no verdict here should be quotable without it.
    """
    fps = float(record["fps"])
    start = float(entry["swing_start_s"])
    results = detector_results(record)

    scored = {"timestamp": entry["timestamp"], "fps": fps,
              "start": start, "window": window,
              "basis": entry.get("label_basis"), "detectors": {}}
    for name, result in results.items():
        if result is None:
            scored["detectors"][name] = None
            continue
        seconds = {e: result[e] / fps for e in EVENTS}
        consistent = all(
            abs(seconds[e] - start) <= window for e in ("takeaway", "top")
        )
        scored["detectors"][name] = {
            "events": {e: result[e] for e in EVENTS},
            "seconds": seconds,
            "distance": {e: seconds[e] - start for e in EVENTS},
            "consistent": consistent,
        }
    return scored


def print_coarse(scored: list[dict]) -> None:
    for swing in scored:
        basis = swing.get("basis") or "basis unrecorded"
        print(f"\n{swing['timestamp']}  swing starts ~{swing['start']:.1f}s "
              f"(+/-{swing['window']:.1f}s)  [read from {basis}]")
        for name, result in swing["detectors"].items():
            if result is None:
                print(f"  {name:<16} returned nothing")
                continue
            verdict = "FOUND the swing" if result["consistent"] else "MISSED it"
            print(f"  {name:<16} {verdict}")
            for event in EVENTS:
                at = result["seconds"][event]
                away = result["distance"][event]
                print(f"      {event:<9} {at:6.2f}s   {away:+6.2f}s from the "
                      f"labelled start")

    # Split by basis rather than pooled. A sheet-read label is derived from
    # the same series the detector consumes, so it cannot fully falsify a
    # detector that is wrong about what that series means; averaging it with a
    # video-read label would launder that weakness into a single number.
    print("\n" + "=" * 62)
    for basis in ("video", "sheet", None):
        subset = [s for s in scored if s.get("basis") == basis]
        if not subset:
            continue
        label = basis or "basis unrecorded"
        print(f"labels read from {label}:")
        for name in ("detect_phases", "locate_swing"):
            judged = [s["detectors"][name] for s in subset
                      if s["detectors"].get(name)]
            if not judged:
                continue
            ok = sum(1 for r in judged if r["consistent"])
            print(f"  {name:<16} found the swing on {ok}/{len(judged)}")


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
    parser.add_argument(
        "--window", type=float, default=None,
        help="tolerance in seconds for a coarse label (default: the file's "
             "coarse_window_s, else 2.0)")
    args = parser.parse_args()

    labels = json.loads(args.labels.read_text())
    records = load_records(args.corpus)

    window = args.window or labels.get("coarse_window_s", 2.0)
    scored, coarse = [], []
    unlabelled = 0
    for entry in labels["swings"]:
        record = records.get(entry["timestamp"])
        if record is None:
            print(f"warning: no record for {entry['timestamp']}; skipping")
            continue
        if any(entry.get(f"{e}_s") is not None for e in EVENTS):
            scored.append(score_swing(entry, record))
        elif entry.get("swing_start_s") is not None:
            coarse.append(score_coarse(entry, record, window))
        else:
            unlabelled += 1

    if not scored and not coarse:
        print(f"No labelled swings yet ({unlabelled} awaiting labels).")
        print(f"Fill in the *_s fields in {args.labels.relative_to(REPO)} "
              "and run again.")
        return

    if scored:
        print_report(scored)
    if coarse:
        print("\n--- coarse labels: does the detector find the swing at "
              "all? ---")
        print_coarse(coarse)
    if unlabelled:
        print(f"\n({unlabelled} swing(s) still unlabelled.)")


if __name__ == "__main__":
    main()
