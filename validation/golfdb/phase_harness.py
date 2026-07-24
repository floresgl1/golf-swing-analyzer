"""Stage 2a: phase-detection validation against GolfDB event labels.

Scope (per the spot-check verdict in README): validate TOP and IMPACT, which
agree with ground truth to +/-1-3 frames at 160x160. FINISH is reported
separately as a definitional-gap candidate (not scored as the headline). TAKEAWAY
is excluded (address-region wrist spikes + the Address-vs-takeaway definitional
gap, P0.2).

Scores detect_phases at TWO smoothing configs from a single pose pass:
  * smooth=5  -- production-shape kernel (240fps width). HEADLINE. Calibration
    showed this is required: at 30fps the 160px wrist tracking is noisy, and
    smoothing suppresses that resolution artifact so the offset measures the
    event-location LOGIC, not the noise.
  * smooth=1  -- native/unsmoothed. Kept only to show smoothing is load-bearing
    (it collapses on low-clarity clips, e.g. id 0: off_top -71 vs -3 at smooth=5).
This corrects the earlier "validate native" note -- see README.

Stamps the pose model sha256 on every row. Offsets are SPLIT by capture type
(real-time vs slow-mo) and NORMALIZED by swing span -- raw frame-offsets are not
comparable across the two (slow-mo swings span ~8x more frames). The clarity gate
was RETIRED after the full run: it measured nothing (r~-0.06 with Top error). See
README "Stage 2a -- RESULTS".

  python validation/golfdb/phase_harness.py --ids 0 2 4 6 12   # calibration
  python validation/golfdb/phase_harness.py --all              # full run
"""
import argparse
import hashlib
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision

sys.path.insert(0, "src")
from swing_phases import detect_phases, LEAD_WRIST, _moving_average

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "manifest_dtl.csv"
VID_DIR = HERE / "cache" / "videos_160"
RESULTS = HERE / "phase_results.csv"
MODEL = Path("data/pose_landmarker.task")

# clarity = (max-min of 5-smoothed height) / std(raw - 5-smoothed). RETIRED as a
# gate: pre-registered at 10 on 5 clips, but on the full 585 it never dips below
# 12.5 (0% dropped) and does not predict error (r~-0.06). Kept computed/recorded
# only as a negative finding -- the real Top-failure predictor is pre-address
# length, and the fix removes the need for any trajectory-quality gate (see
# README). Do not re-introduce a clarity/plausibility gate; that is the P0.2
# address-onset fix in weaker form.
SMOOTHINGS = (5, 1)   # headline first


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def _lm():
    bo = python.BaseOptions(model_asset_path=str(MODEL))
    return vision.PoseLandmarker.create_from_options(
        vision.PoseLandmarkerOptions(base_options=bo, running_mode=vision.RunningMode.VIDEO))


def wrist_series(path):
    wy, vis = [], []
    cap = cv2.VideoCapture(str(path))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    n = 0
    with _lm() as lm:
        while True:
            ret, fr = cap.read()
            if not ret:
                break
            rgb = cv2.cvtColor(fr, cv2.COLOR_BGR2RGB)
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb),
                                      int(n * 1000 / fps))
            n += 1
            if res.pose_landmarks:
                p = res.pose_landmarks[0][LEAD_WRIST]
                wy.append(p.y); vis.append(p.visibility)
            else:
                wy.append(np.nan); vis.append(np.nan)
    cap.release()
    return np.array(wy, float), np.array(vis, float), fps


def clarity(wy):
    good = ~np.isnan(wy)
    if good.sum() < 8:
        return np.nan
    y = np.interp(np.arange(len(wy)), np.flatnonzero(good), wy[good])
    h = 1.0 - y
    h5 = _moving_average(h, 5)
    resid = float(np.std(h - h5))
    amp = float(h5.max() - h5.min())
    return amp / resid if resid > 0 else np.inf


def run(clips, model_hash):
    rows = []
    for i, r in enumerate(clips, 1):
        cid = int(r["id"])
        path = VID_DIR / f"{cid}.mp4"
        if not path.exists():
            continue
        wy, vis, fps = wrist_series(path)
        clr = clarity(wy)
        cs = int(r["addr_frame"]) - int(r["pre_address_frames"])   # events[0]
        lab = {"top": int(r["top_frame"]) - cs,
               "impact": int(r["impact_frame"]) - cs,
               "finish": int(r["finish_frame"]) - cs}
        row = {"id": cid, "player": r["player"], "slow": int(r["slow"]),
               "fps": round(fps, 3), "pose_rate": float(np.mean(~np.isnan(wy))),
               "wrist_vis_med": float(np.nanmedian(vis)) if np.isfinite(vis).any() else np.nan,
               "clarity": clr, "model_sha256": model_hash,
               "swing_span_frames": int(r["swing_span_frames"]),
               "pre_address_frames": int(r["pre_address_frames"])}
        ok = False
        for sm in SMOOTHINGS:                    # one pose pass, two detect_phases
            ph = detect_phases(wy, smooth=sm)
            if ph is not None:
                ok = True
                for e in ("top", "impact", "finish"):
                    row[f"off_{e}_s{sm}"] = ph[e] - lab[e]
        row["detected"] = ok
        rows.append(row)
        if i % 25 == 0 or i == len(clips):
            print(f"  processed {i}/{len(clips)} ...", flush=True)
    return pd.DataFrame(rows)


def _dist(s):
    s = s.dropna()
    return (f"n={len(s):>3}  mean={s.mean():+5.1f}  med={s.median():+4.0f}  "
            f"sd={s.std():4.1f}  IQR=[{s.quantile(.25):+.0f},{s.quantile(.75):+.0f}]  "
            f"p5/p95=[{s.quantile(.05):+.0f},{s.quantile(.95):+.0f}]")


def _pctcol(g, e, sm):
    return 100 * g[f"off_{e}_s{sm}"] / g["span"]


def report(df):
    # swing_span / pre_address are needed for normalization + the predictor;
    # merge from the manifest for result CSVs written before those columns existed.
    missing = {"swing_span_frames", "pre_address_frames"} - set(df.columns)
    if missing:
        man = pd.read_csv(MANIFEST)[["id", "swing_span_frames", "pre_address_frames"]]
        df = df.merge(man, on="id", how="left")
    df = df.copy()
    df["span"] = df["swing_span_frames"].clip(lower=1)
    det = df[df["detected"]].copy()
    rt, sm_ = det[det["slow"] == 0], det[det["slow"] == 1]

    print(f"\ndetect_phases vs GolfDB labels: {len(df)} clips, {len(df)-len(det)} failed")
    print("  offsets NORMALIZED by swing span and SPLIT by capture type -- raw frames")
    print("  are not comparable across real-time vs slow-mo (~8x frame-scale). The")
    print("  clarity gate was RETIRED (measured nothing); see README.")

    for sm in SMOOTHINGS:
        tag = "HEADLINE, production-shape" if sm == 5 else "native, load-bearing contrast"
        print(f"\n######## smooth={sm}  ({tag}) -- offset as % of swing span ########")
        for e in ("top", "impact", "finish"):
            if f"off_{e}_s{sm}" not in det:
                continue
            for gname, g in (("real-time", rt), ("slow-mo", sm_)):
                print(f"  {e:7} {gname:10} {_dist(_pctcol(g, e, sm))}")

    # Finish: definitional gap should be consistent across groups once normalized.
    print("\n--- FINISH: definitional gap (normalized, @smooth=5) ---")
    for gname, g in (("real-time", rt), ("slow-mo", sm_)):
        p = _pctcol(g, "finish", 5)
        print(f"  {gname:10}: median {p.median():+.1f}% of swing")
    print("  consistent across groups => our wrist-peak finish precedes GolfDB's")
    print("  posed Finish by a fixed fraction of the swing => definitional, not fps.")

    # Pre-address = the real Top-failure predictor, checked WITHIN each group
    # (pooling inflates it -- same lesson the finish result taught).
    print("\n--- TOP-failure predictor: pre-address length, WITHIN group (@smooth=5) ---")
    for gname, g in (("pooled", det), ("real-time", rt), ("slow-mo", sm_)):
        ap = _pctcol(g, "top", 5).abs()
        r = ap.corr(g["pre_address_frames"])
        big = g[ap > 10]
        clean = g[ap <= 10]
        print(f"  {gname:10}: corr(|Top%|, pre_addr)={r:+.2f}  |Top|>10%swing: "
              f"{len(big)}/{len(g)} ({100*len(big)/len(g):.0f}%)  fail pre-addr median="
              f"{big['pre_address_frames'].median():.0f} vs clean {clean['pre_address_frames'].median():.0f}")
    print("  real-time: pre-address drives it (the P0.2 address-onset bound fixes it).")
    print("  slow-mo:   r~0 -- a SEPARATE population, driven by under-smoothing (clarity")
    print("             predicts it, r=-0.26 within group; see the CLARITY section).")

    # Clarity: retired as a GATE, but NOT useless. Pooled it looks null because
    # real-time failures are pre-address-driven (clarity-irrelevant), which washes
    # out the slow-mo signal -- the same pooling trap as finish and pre-address.
    # WITHIN slow-mo, low clarity predicts the under-smoothing failures.
    print("\n--- CLARITY: gate retired, but it predicts the SLOW-MO failures ---")
    for gname, g in (("pooled", det), ("real-time", rt), ("slow-mo", sm_)):
        print(f"  {gname:10}: corr(|Top%|, clarity)={_pctcol(g, 'top', 5).abs().corr(g['clarity']):+.2f}")
    # smooth=1->5 improvement: if slow-mo is under-smoothed, more smoothing helps
    # it far more than real-time.
    def _impr(g):
        return (_pctcol(g, "top", 5).abs() - _pctcol(g, "top", 1).abs()).median()
    print(f"  smooth1->5 Top |err%| change (neg=more smoothing better): "
          f"slow-mo {_impr(sm_):+.1f}  real-time {_impr(rt):+.1f}")
    print("  => slow-mo failures = under-smoothing (kernel covers ~8x less of the swing")
    print("     at ~8x more frames). Fix = a swing-duration-relative kernel, which also")
    print("     needs detect_address_onset (know where the swing starts). See P0.2.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", type=int, nargs="+", help="specific clip ids (calibration)")
    ap.add_argument("--all", action="store_true", help="all down-the-line clips")
    ap.add_argument("--report-only", action="store_true",
                    help="skip processing; re-run the report on the saved results CSV")
    args = ap.parse_args()

    if args.report_only:
        report(pd.read_csv(RESULTS))
        return

    df = pd.read_csv(MANIFEST)
    if args.ids:
        clips = [df[df["id"] == i].iloc[0] for i in args.ids]
    elif args.all:
        clips = [r for _, r in df.iterrows()]
    else:
        ap.error("pass --ids ... or --all")

    model_hash = sha256(MODEL)
    print(f"model sha256: {model_hash[:16]}...  clips: {len(clips)}")
    res = run(clips, model_hash)
    res.to_csv(RESULTS, index=False)
    print(f"wrote {RESULTS}")
    report(res)


if __name__ == "__main__":
    main()
