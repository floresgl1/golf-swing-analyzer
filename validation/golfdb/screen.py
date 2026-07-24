"""GolfDB Stage-1 screening: ingestion + filters ONLY (no validation).

Answers, from the annotation database alone (NO video downloads):
  1. how many clips survive the down-the-line view filter
  2. the frame-rate-risk distribution -- via the annotated `slow` flag, which is
     a BETTER screen than CAP_PROP_FPS here: for slow-motion clips CAP_PROP_FPS
     reports the deceptive CONTAINER rate (the exact container-vs-capture bug the
     pipeline just fixed), so container fps must never be fed into frames_for.
  3. how many clips have any settled pre-address frames (events[1]-events[0]),
     the footage the address-onset fix needs to anchor a baseline.

It also writes a per-clip manifest that carries the metadata discipline Stage 2
requires from the start:
  * capture_fps (blank) + capture_fps_source ('unknown') -- Stage 2 must REFUSE
    to run on any row whose capture_fps is unestablished, rather than silently
    trusting CAP_PROP_FPS.
  * model_sha256 (blank) -- filled when a detector actually runs, so every
    result is tied to a known pose model (see tests/test_pose_estimation.py for
    why variant identity matters).

GolfDB: McNally et al., "GolfDB: A Video Database for Golf Swing Sequencing",
CVPRW 2019 (github.com/wmcnally/golfdb). The annotation DB is redistributed in
that repo; the videos are not -- they are YouTube IDs re-downloaded and trimmed.

Run:  python validation/golfdb/screen.py            (screen + write manifest)
      python validation/golfdb/screen.py --refresh  (re-download the DB)
"""
import argparse
import hashlib
from pathlib import Path

import numpy as np
import pandas as pd
import requests

DB_URL = "https://raw.githubusercontent.com/wmcnally/golfdb/master/data/golfDB.pkl"
HERE = Path(__file__).resolve().parent
CACHE = HERE / "cache" / "golfDB.pkl"
MANIFEST = HERE / "manifest_dtl.csv"

# GolfDB `events` layout, confirmed from the repo's dataloader.py:
#   events[0]      = clip START frame (in the original video)
#   events[1..8]   = the 8 swing events --
#                    1 Address, 2 Toe-up, 3 Mid-backswing, 4 Top,
#                    5 Mid-downswing, 6 Impact, 7 Mid-follow-through, 8 Finish
#   events[9]      = clip END frame
E_START, E_ADDRESS, E_TOP, E_IMPACT, E_FINISH, E_END = 0, 1, 4, 6, 8, 9

# Our capture spec (see ROADMAP P0.1). Real-time YouTube is typically ~30 fps,
# below this floor; slow-mo clips have a deceptive container rate. Both fail the
# spec -- GolfDB is a validation aid, not a corpus that meets it.
MIN_CAPTURE_FPS = 120


def sha256_of(path):
    """Hex SHA-256 of a file (used at Stage 2 to stamp the pose model)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_db(refresh=False):
    if refresh or not CACHE.exists():
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        r = requests.get(DB_URL, timeout=120)
        r.raise_for_status()
        CACHE.write_bytes(r.content)
    return pd.read_pickle(CACHE)


def annotate(df):
    """Add per-clip event-derived columns from the raw `events` array."""
    ev = np.stack(df["events"].values)
    return df.assign(
        addr_frame=ev[:, E_ADDRESS],
        top_frame=ev[:, E_TOP],
        impact_frame=ev[:, E_IMPACT],
        finish_frame=ev[:, E_FINISH],
        pre_address_frames=ev[:, E_ADDRESS] - ev[:, E_START],
        swing_span_frames=ev[:, E_FINISH] - ev[:, E_ADDRESS],
        post_finish_frames=ev[:, E_END] - ev[:, E_FINISH],
    )


def report(df):
    n = len(df)
    print(f"TOTAL clips: {n}\n")

    print("[1] VIEW FILTER")
    print(df["view"].value_counts().to_string())
    dtl = df[df["view"] == "down-the-line"].copy()
    print(f"  -> down-the-line: {len(dtl)}\n")

    print("[2] FRAME-RATE RISK (annotation `slow` flag -- see module docstring;")
    print("    CAP_PROP_FPS would report the deceptive CONTAINER rate)")
    rt, sm = dtl[dtl["slow"] == 0], dtl[dtl["slow"] == 1]
    print(f"    real-time (slow=0): {len(rt)}    slow-mo (slow=1): {len(sm)}")
    print("    real-time YouTube is typically ~30 fps (< the >=120 floor);")
    print("    slow-mo has a deceptive container rate + ramped-tempo risk.\n")

    print("[3] PRE-ADDRESS FRAMES (events[1]-events[0]) within down-the-line")
    pa = dtl["pre_address_frames"].values
    print(f"    any pre-address (>0): {(pa > 0).sum()}/{len(dtl)} "
          f"({100 * (pa > 0).mean():.0f}%)   zero: {(pa == 0).sum()}")
    pct = {q: np.percentile(pa, q) for q in (10, 25, 50, 75, 90)}
    print("    percentiles(frames): " +
          "  ".join(f"p{q}={v:.0f}" for q, v in pct.items()))
    for thr in (8, 15, 30):
        print(f"    >= {thr:>2} frames: {(pa >= thr).sum():>3} "
              f"({100 * (pa >= thr).mean():.0f}%)")
    print("    NOTE: frames, not seconds -- the >=0.5 s settled-address check "
          "needs\n    per-clip capture fps, which is unestablished (see manifest).\n")

    print("[4] BODY-TYPE METADATA (the actual P0 goal)")
    print(f"    sex only: {dict(dtl['sex'].value_counts())}")
    print("    NO height / build / BMI field exists -> body-type variation is "
          "NOT\n    recoverable from GolfDB. It cannot substitute for controlled "
          "capture.\n")
    return dtl


def write_manifest(dtl):
    """Per-clip manifest for down-the-line clips, with the Stage-2 discipline
    columns pre-created and blank."""
    cols = ["id", "youtube_id", "player", "sex", "club", "view", "slow", "split",
            "addr_frame", "top_frame", "impact_frame", "finish_frame",
            "pre_address_frames", "swing_span_frames", "post_finish_frames"]
    m = dtl[cols].copy()
    # Explicit, unestablished-by-design metadata. Stage 2 MUST refuse rows where
    # capture_fps is blank rather than fall back to CAP_PROP_FPS.
    m["capture_fps"] = ""            # established per clip in Stage 2, never guessed
    m["capture_fps_source"] = "unknown"   # unknown | container | manual | metadata
    m["model_sha256"] = ""          # stamped when a detector runs on this clip
    m.to_csv(MANIFEST, index=False)
    print(f"[manifest] wrote {len(m)} down-the-line rows -> {MANIFEST}")
    print("           capture_fps left BLANK by design (Stage-2 refuse-to-run gate).")


def main():
    ap = argparse.ArgumentParser(description="GolfDB Stage-1 screening (no videos).")
    ap.add_argument("--refresh", action="store_true", help="re-download the annotation DB")
    args = ap.parse_args()

    df = annotate(load_db(refresh=args.refresh))
    dtl = report(df)
    write_manifest(dtl)


if __name__ == "__main__":
    main()
