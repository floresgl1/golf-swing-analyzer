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

Stamps the pose model sha256 on every row. Applies a PRE-REGISTERED clarity gate
(see README / CLARITY_MIN) so degraded-trajectory clips are dropped rather than
trusted, and reports the drop rate + offsets both gated and ungated.

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

# PRE-REGISTERED clarity gate -- swing amplitude in units of per-frame jitter,
# clarity = (max-min of 5-smoothed height) / std(raw height - 5-smoothed height).
# Calibrated on the 5 spot-check clips BEFORE the full run (see README): they span
# clarity 13.3-41.3 and all detect Top/Impact well at smooth=5; the lowest (id 0,
# 13.3, visible address spikes) is our marginal-but-working case. Gate at 10 ->
# just below it, so clips at least that clean are admitted and clearly-worse ones
# are flagged. Do NOT tune against the full-run offsets -- that would be circular.
CLARITY_MIN = 10.0
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
               "clarity": clr, "model_sha256": model_hash}
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


def report(df):
    det = df[df["detected"]]
    print(f"\nclips: {len(df)}  detect_phases ok: {len(det)}  failed: {len(df)-len(det)}")
    gate = det["clarity"] >= CLARITY_MIN
    dropped = (~gate).sum()
    print(f"CLARITY gate (>= {CLARITY_MIN}): pass {gate.sum()}  drop {dropped} "
          f"({100*dropped/max(len(det),1):.0f}%)  "
          f"<- headline agreement describes the {gate.sum()} passing clips")

    for sm in SMOOTHINGS:
        tag = "HEADLINE, production-shape" if sm == 5 else "native/unsmoothed (load-bearing check)"
        print(f"\n######## smooth={sm}  ({tag}) ########")
        for name, sub in (("ALL detected", det), (f"GATED (clarity>={CLARITY_MIN})", det[gate])):
            print(f"  -- {name} --")
            for e in ("top", "impact", "finish"):
                col = f"off_{e}_s{sm}"
                if col in sub:
                    print(f"    {e:7} offset  {_dist(sub[col])}")

    # Finish: definitional vs detection-error (at the headline smooth=5). A
    # definitional gap is tight & clarity-independent; a detection error scatters
    # more on low-clarity clips.
    print("\n--- FINISH offset vs clarity @smooth=5 (definitional check) ---")
    d = det.dropna(subset=["off_finish_s5", "clarity"])
    if len(d) > 5:
        rho = np.corrcoef(d["clarity"], d["off_finish_s5"].abs())[0, 1]
        med = d["clarity"].median()
        lo, hi = d[d["clarity"] < med]["off_finish_s5"], d[d["clarity"] >= med]["off_finish_s5"]
        print(f"  corr(|finish offset|, clarity) = {rho:+.2f}  "
              f"(strong negative => degraded clips worse => NOT purely definitional)")
        print(f"  low-clarity half : mean={lo.mean():+.1f} sd={lo.std():.1f} (n={len(lo)})")
        print(f"  high-clarity half: mean={hi.mean():+.1f} sd={hi.std():.1f} (n={len(hi)})")
    # TOP/IMPACT vs clarity @smooth=5 -- the kernel's-limit check. At 160px the
    # kernel absorbs tracking artifact, so residual offset partly reflects how
    # noisy the clip was: if |offset| rises as clarity falls, that's where the
    # approach degrades (not just a gate sanity check).
    print("\n--- TOP/IMPACT offset vs clarity @smooth=5 (kernel's-limit check) ---")
    for e in ("top", "impact"):
        d = det.dropna(subset=[f"off_{e}_s5", "clarity"])
        if len(d) < 6:
            continue
        rho = np.corrcoef(d["clarity"], d[f"off_{e}_s5"].abs())[0, 1]
        med = d["clarity"].median()
        lo, hi = d[d["clarity"] < med][f"off_{e}_s5"], d[d["clarity"] >= med][f"off_{e}_s5"]
        print(f"  {e:7}: corr(|offset|,clarity)={rho:+.2f}  "
              f"low-clarity sd={lo.std():.1f}  high-clarity sd={hi.std():.1f}  "
              f"(strong neg => error rises as clarity falls => kernel's limit)")


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
