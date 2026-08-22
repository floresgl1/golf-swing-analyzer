import cv2
import mediapipe as mp
from mediapipe.tasks import python
from mediapipe.tasks.python import vision
import numpy as np
import math
import sys

from swing_phases import (detect_phases, implausible_swing, require_valid_fps,
                          swing_tempo, LEAD_WRIST,
                          BASELINE_FPS, frames_for,
                          IMPACT_RADIUS_S, DEFAULT_RADIUS_S, ADDRESS_OFFSET_S)
from drill_recommender import print_recommendations
from swing_history import (FAULT_METRICS, build_session, load_sessions,
                           save_session, print_comparison)

# MediaPipe landmark indices
LEFT_EYE = 2       # The eye midpoint sits near the head's rotation axis, so it
RIGHT_EYE = 5      # reports true head translation without inflating on head
LEFT_SHOULDER = 11  # turn (unlike the nose, which swings as the face rotates).
RIGHT_SHOULDER = 12
LEFT_HIP = 23
RIGHT_HIP = 24

VIDEO_PATH = 'data/videos/videoplayback.mp4'
HEAD_OUTPUT = 'output/head_movement.png'
PIVOT_OUTPUT = 'output/reverse_pivot.png'
EXTENSION_OUTPUT = 'output/early_extension.png'
POSTURE_OUTPUT = 'output/loss_of_posture.png'

# Head-movement thresholds as a fraction of torso length (address->impact).
# Lateral sway is the primary fault; vertical dip is informational and uses a
# looser threshold because some downward "sit" into impact is normal/athletic.
SWAY_THRESHOLD = 0.13   # lateral -> the flagged fault
DIP_THRESHOLD = 0.25    # vertical -> informational only

# Reverse pivot: fraction of torso length the head leans TOWARD the target
# (relative to the hips) from address to the top of the backswing.
REVERSE_PIVOT_THRESHOLD = 0.12

# Early extension: fraction of torso length the pelvis rises (stands up toward
# the ball) from address to impact.
EARLY_EXTENSION_THRESHOLD = 0.10

# Loss of posture: degrees the spine straightens (stands more upright) from
# address to impact.
POSTURE_THRESHOLD = 12.0


def _addr_median(a, takeaway, fps=BASELINE_FPS):
    """Median of a[] over the setup window ending at the takeaway.

    The look-back is ADDRESS_OFFSET_S resolved to frames at `fps` (10 frames at
    BASELINE_FPS). KNOWN ISSUE: this window ends at the wrist-defined takeaway,
    which fires after body motion has already begun, so it does not actually
    sample a settled address -- see the ADDRESS_OFFSET_S note in swing_phases.py.
    Preserved as-is pending the address-onset fix (ROADMAP P0).
    """
    offset = frames_for(ADDRESS_OFFSET_S, fps)
    a = np.asarray(a, dtype=float)
    return np.nanmedian(a[max(0, takeaway - offset):takeaway + 1])


def _window_median(a, center, radius_s=DEFAULT_RADIUS_S, fps=BASELINE_FPS):
    """Median of a[] over a small window centered on a frame.

    `radius_s` is the half-window in seconds resolved to frames at `fps`. Impact
    windows pass IMPACT_RADIUS_S (kept tight so the post-impact follow-through
    rise is not averaged in); top/finish windows use the DEFAULT_RADIUS_S
    default. At BASELINE_FPS these are the historic radius=2 and radius=3.
    """
    radius = frames_for(radius_s, fps)
    a = np.asarray(a, dtype=float)
    i0, i1 = max(0, center - radius), min(len(a) - 1, center + radius)
    return np.nanmedian(a[i0:i1 + 1])


def _spine_tilt(sh, hip):
    """Spine tilt from vertical, in degrees (unsigned), from hip to shoulder."""
    dx = sh[0] - hip[0]
    up = hip[1] - sh[1]      # shoulder sits above hip -> positive
    return math.degrees(math.atan2(abs(dx), abs(up)))


def detect_head_movement(head_x, head_y, torso, phases,
                         sway_threshold=SWAY_THRESHOLD, dip_threshold=DIP_THRESHOLD,
                         fps=BASELINE_FPS):
    """Flag excessive head movement between address and impact.

    Head drift is the distance the head point (eye midpoint) travels from its
    address position to its impact position, expressed as a fraction of the
    golfer's torso length so the threshold is resolution- and size-independent.
    The flagged fault is lateral sway; vertical dip is informational.
    """
    if not phases:
        return None
    hx = np.asarray(head_x, dtype=float)
    hy = np.asarray(head_y, dtype=float)
    ta, im = phases['takeaway'], phases['impact']

    addr = (_addr_median(hx, ta, fps), _addr_median(hy, ta, fps))
    scale = _addr_median(torso, ta, fps)
    imp = (_window_median(hx, im, IMPACT_RADIUS_S, fps),
           _window_median(hy, im, IMPACT_RADIUS_S, fps))

    dx, dy = imp[0] - addr[0], imp[1] - addr[1]
    dist_px = math.hypot(dx, dy)
    lateral = abs(dx) / scale if scale else float('nan')
    vertical = abs(dy) / scale if scale else float('nan')
    return {
        'lateral': lateral, 'vertical': vertical,
        'total': dist_px / scale if scale else float('nan'), 'dist_px': dist_px,
        'sway_threshold': sway_threshold, 'dip_threshold': dip_threshold,
        'sway_flagged': lateral > sway_threshold,
        'dip_flagged': vertical > dip_threshold,
        'flagged': lateral > sway_threshold,   # head-movement fault = sway
        'address_px': addr, 'impact_px': imp,
    }


def detect_reverse_pivot(head_x, head_y, hip_x, hip_y, torso, phases,
                         threshold=REVERSE_PIVOT_THRESHOLD, fps=BASELINE_FPS):
    """Flag a reverse pivot: upper body leaning toward the target at the top.

    Measures the head's horizontal position relative to the hips, and how much
    it shifts toward the target from address to the top of the backswing,
    normalized by torso length. Target direction is derived from the swing
    itself (net hip translation address->finish). Positive = reverse pivot.
    """
    if not phases:
        return None
    hx, hpx = np.asarray(head_x, float), np.asarray(hip_x, float)
    ta, top, fin = phases['takeaway'], phases['top'], phases['finish']

    head_addr, hip_addr = _addr_median(hx, ta, fps), _addr_median(hpx, ta, fps)
    scale = _addr_median(torso, ta, fps)
    head_top, hip_top = _window_median(hx, top, fps=fps), _window_median(hpx, top, fps=fps)
    hip_fin = _window_median(hpx, fin, fps=fps)

    target_sign = 1.0 if hip_fin >= hip_addr else -1.0
    lean_shift = (head_top - hip_top) - (head_addr - hip_addr)
    reverse = lean_shift * target_sign / scale if scale else float('nan')
    return {
        'reverse': reverse, 'threshold': threshold,
        'flagged': reverse > threshold, 'target_sign': target_sign,
        'top_frame': top,
        'head_top_px': (head_top, _window_median(head_y, top, fps=fps)),
        'hip_top_px': (hip_top, _window_median(hip_y, top, fps=fps)),
    }


def detect_early_extension(hip_y, torso, phases, threshold=EARLY_EXTENSION_THRESHOLD,
                           fps=BASELINE_FPS):
    """Flag early extension: the pelvis thrusting up/toward the ball downswing.

    Measured as how far the hip midpoint rises from address to impact, as a
    fraction of torso length. In a down-the-line view the pure toward-ball
    motion is along the camera axis; the visible co-symptom is the pelvis
    rising, which is what this uses.
    """
    if not phases:
        return None
    hy = np.asarray(hip_y, float)
    ta, im = phases['takeaway'], phases['impact']
    hip_addr = _addr_median(hy, ta, fps)
    hip_impact = _window_median(hy, im, IMPACT_RADIUS_S, fps)
    scale = _addr_median(torso, ta, fps)
    rise = (hip_addr - hip_impact) / scale if scale else float('nan')  # + = rose
    return {
        'rise': rise, 'threshold': threshold, 'flagged': rise > threshold,
        'hip_addr_y': hip_addr, 'hip_impact_y': hip_impact,
    }


def detect_loss_of_posture(sh_x, sh_y, hip_x, hip_y, phases, threshold=POSTURE_THRESHOLD,
                           fps=BASELINE_FPS):
    """Flag loss of posture: the spine's forward bend straightening address->impact.

    Measured as the drop in spine tilt from vertical, in degrees; a large
    decrease means the golfer stood up out of their setup posture.
    """
    if not phases:
        return None
    ta, im = phases['takeaway'], phases['impact']
    sh_addr = (_addr_median(sh_x, ta, fps), _addr_median(sh_y, ta, fps))
    hip_addr = (_addr_median(hip_x, ta, fps), _addr_median(hip_y, ta, fps))
    sh_imp = (_window_median(sh_x, im, fps=fps), _window_median(sh_y, im, fps=fps))
    hip_imp = (_window_median(hip_x, im, fps=fps), _window_median(hip_y, im, fps=fps))
    tilt_addr = _spine_tilt(sh_addr, hip_addr)
    tilt_impact = _spine_tilt(sh_imp, hip_imp)
    return {
        'tilt_addr': tilt_addr, 'tilt_impact': tilt_impact,
        'straighten': tilt_addr - tilt_impact, 'threshold': threshold,
        'flagged': (tilt_addr - tilt_impact) > threshold,
        'sh_addr_px': sh_addr, 'hip_addr_px': hip_addr,
        'sh_impact_px': sh_imp, 'hip_impact_px': hip_imp,
    }


def _draw_verdict_text(img, lines, flagged):
    color = (0, 0, 255) if flagged else (0, 255, 0)
    for i, text in enumerate(lines):
        y = 30 + i * 30
        cv2.putText(img, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 4, cv2.LINE_AA)
        c = color if i == len(lines) - 1 else (255, 255, 255)
        cv2.putText(img, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, 0.7, c, 2, cv2.LINE_AA)


def _read_frame(index):
    cap = cv2.VideoCapture(VIDEO_PATH)
    cap.set(cv2.CAP_PROP_POS_FRAMES, index)
    ret, frame = cap.read()
    cap.release()
    return frame if ret else None


def _ipt(p):
    return (int(p[0]), int(p[1]))


def main():
    # Optional CLI arg: the fault id the golfer is practicing against this
    # session (e.g. `python src/faults.py head_sway`). Recorded in the swing
    # history so the next comparison can call out whether the focus paid off.
    targeting = sys.argv[1] if len(sys.argv) > 1 else None
    if targeting and targeting not in FAULT_METRICS:
        print(f"Unknown fault id '{targeting}' -- valid ids: "
              f"{', '.join(FAULT_METRICS)}. Not recording a focus fault.")
        targeting = None

    base_options = python.BaseOptions(model_asset_path='data/pose_landmarker.task')
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        running_mode=vision.RunningMode.VIDEO
    )

    eye_x, eye_y, sh_x, sh_y, hip_x, hip_y, torso, wrist_y = ([] for _ in range(8))

    with vision.PoseLandmarker.create_from_options(options) as landmarker:
        cap = cv2.VideoCapture(VIDEO_PATH)
        # CONTAINER fps -- valid for the tempo ratio (frame-based), timestamps,
        # and for the LOCALIZATION path (locate_swing / stance_bounds), whose
        # duration-based windows depend only on frame spacing, not capture rate.
        # For real-time clips (all device recordings) container fps = capture fps
        # and everything is correct. For slow-mo clips they differ: the localization
        # windows cover less real time, and the smoothing is lighter. The slow-mo
        # case is the calibration clip only -- see BASELINE_FPS in swing_phases.py.
        #
        # The DETECTOR windows (_addr_median, _window_median) stay on their
        # BASELINE_FPS default: they were calibrated at 240 fps, and that seam is
        # held until P0.2 threads a real capture_fps. Do not pass this fps into
        # the four detector functions.
        fps = require_valid_fps(cap.get(cv2.CAP_PROP_FPS), VIDEO_PATH)
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        frame_count = 0

        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                break
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            results = landmarker.detect_for_video(mp_image, int(frame_count * 1000 / fps))
            frame_count += 1

            if results.pose_landmarks:
                lm = results.pose_landmarks[0]
                eye_x.append((lm[LEFT_EYE].x + lm[RIGHT_EYE].x) / 2 * width)
                eye_y.append((lm[LEFT_EYE].y + lm[RIGHT_EYE].y) / 2 * height)
                sx = (lm[LEFT_SHOULDER].x + lm[RIGHT_SHOULDER].x) / 2 * width
                sy = (lm[LEFT_SHOULDER].y + lm[RIGHT_SHOULDER].y) / 2 * height
                hx = (lm[LEFT_HIP].x + lm[RIGHT_HIP].x) / 2 * width
                hy = (lm[LEFT_HIP].y + lm[RIGHT_HIP].y) / 2 * height
                sh_x.append(sx); sh_y.append(sy)
                hip_x.append(hx); hip_y.append(hy)
                torso.append(math.dist((sx, sy), (hx, hy)))
                wrist_y.append(lm[LEAD_WRIST].y)
            else:
                for lst in (eye_x, eye_y, sh_x, sh_y, hip_x, hip_y, torso, wrist_y):
                    lst.append(np.nan)

        cap.release()

    phases = detect_phases(wrist_y, fps=fps, torso=torso, hip_x=hip_x)
    # Refuse outright rather than printing verdicts computed from a trajectory
    # that cannot be a swing. Partial output is the same failure in a smaller
    # costume: it invites the surviving numbers to be read as meaningful.
    # With hip_x, detect_phases returns None when no stance is found -- that
    # is the answer ("never stood still, so no swing"), not a gap.
    reason = implausible_swing(phases)
    if reason:
        print(f"No swing detected - {reason}. No fault verdicts.")
        return

    head = detect_head_movement(eye_x, eye_y, torso, phases)
    pivot = detect_reverse_pivot(eye_x, eye_y, hip_x, hip_y, torso, phases)
    extension = detect_early_extension(hip_y, torso, phases)
    posture = detect_loss_of_posture(sh_x, sh_y, hip_x, hip_y, phases)

    def mark(flag):
        return 'FLAGGED' if flag else 'OK'

    print("\n=== Swing fault report ===")
    print("\nHead movement (address -> impact):")
    print(f"  Lateral sway: {head['lateral']:.2f} torso-lengths  "
          f"[threshold {head['sway_threshold']:.2f}]  -> {mark(head['sway_flagged'])}")
    print(f"  Vertical dip: {head['vertical']:.2f} torso-lengths  "
          f"[threshold {head['dip_threshold']:.2f}]  -> {mark(head['dip_flagged'])}  (informational)")
    print(f"  Verdict: {mark(head['flagged'])}" +
          (" - lateral head sway" if head['flagged'] else " - no sway fault"))

    print("\nReverse pivot (address -> top of backswing):")
    toward = 'toward target' if pivot['reverse'] >= 0 else 'away from target (correct)'
    print(f"  Spine lean: {pivot['reverse']:+.2f} torso-lengths {toward}  "
          f"[threshold {pivot['threshold']:.2f}]")
    print(f"  Verdict: {mark(pivot['flagged'])}" +
          (" - reverse pivot" if pivot['flagged'] else " - spine tilts correctly"))

    print("\nEarly extension (address -> impact):")
    print(f"  Pelvis rise: {extension['rise']:+.2f} torso-lengths  "
          f"[threshold {extension['threshold']:.2f}]")
    print(f"  Verdict: {mark(extension['flagged'])}" +
          (" - early extension (pelvis toward ball)" if extension['flagged']
           else " - pelvis stable"))

    print("\nLoss of posture (address -> impact):")
    print(f"  Spine tilt: {posture['tilt_addr']:.0f} deg -> {posture['tilt_impact']:.0f} deg "
          f"(straightened {posture['straighten']:+.0f} deg)  "
          f"[threshold {posture['threshold']:.0f} deg]")
    print(f"  Verdict: {mark(posture['flagged'])}" +
          (" - stood up out of posture" if posture['flagged'] else " - posture maintained"))

    # Recommend corrective drills for whatever faults were flagged above.
    fault_report = {
        'head_sway': head,
        'reverse_pivot': pivot,
        'early_extension': extension,
        'loss_of_posture': posture,
    }
    print_recommendations(fault_report)

    # Verification loop: log this session to the swing history, then show how
    # it stacks up against the previous one so the golfer can see whether the
    # practice is working.
    session = build_session(fault_report, swing_tempo(phases, fps), targeting)
    history = load_sessions()
    save_session(session)
    if history:
        print_comparison(history[-1], session)
    else:
        print("\nSwing history started -- run the analyzer again after "
              "practicing to see your progress.")

    # ---- Visual: head movement ----
    bg = _read_frame(phases['takeaway'])
    if bg is not None:
        path = [_ipt((eye_x[i], eye_y[i]))
                for i in range(phases['takeaway'], phases['impact'] + 1)
                if np.isfinite(eye_x[i]) and np.isfinite(eye_y[i])]
        if len(path) >= 2:
            cv2.polylines(bg, [np.array(path, np.int32)], False, (0, 255, 255), 2)
        addr, imp = _ipt(head['address_px']), _ipt(head['impact_px'])
        cv2.line(bg, addr, imp, (255, 255, 255), 1, cv2.LINE_AA)
        cv2.circle(bg, addr, 6, (0, 255, 0), -1)
        cv2.circle(bg, imp, 6, (0, 0, 255), -1)
        _draw_verdict_text(bg, [
            f'Sway {head["lateral"]:.2f}  Dip {head["vertical"]:.2f} (torso-len)',
            f'Sway threshold {head["sway_threshold"]:.2f}  ->  '
            f'{"SWAY FAULT" if head["flagged"] else "OK"}',
        ], head['flagged'])
        cv2.imwrite(HEAD_OUTPUT, bg)

    # ---- Visual: reverse pivot ----
    bg = _read_frame(phases['top'])
    if bg is not None:
        hip_pt, eye_pt = _ipt(pivot['hip_top_px']), _ipt(pivot['head_top_px'])
        cv2.line(bg, hip_pt, eye_pt, (255, 200, 0), 3, cv2.LINE_AA)
        cv2.circle(bg, hip_pt, 6, (255, 0, 255), -1)
        cv2.circle(bg, eye_pt, 6, (0, 255, 255), -1)
        ax, ay = 250, 120
        cv2.arrowedLine(bg, (ax, ay), (ax + int(pivot['target_sign'] * 55), ay),
                        (255, 255, 255), 2, cv2.LINE_AA, tipLength=0.3)
        cv2.putText(bg, 'target', (ax - 20, ay - 10), cv2.FONT_HERSHEY_SIMPLEX,
                    0.5, (255, 255, 255), 1, cv2.LINE_AA)
        _draw_verdict_text(bg, [
            f'Spine lean {pivot["reverse"]:+.2f} toward target',
            f'threshold {pivot["threshold"]:.2f}  ->  '
            f'{"REVERSE PIVOT" if pivot["flagged"] else "OK"}',
        ], pivot['flagged'])
        cv2.imwrite(PIVOT_OUTPUT, bg)

    # ---- Visual: early extension (address hip level vs impact hip) ----
    bg = _read_frame(phases['impact'])
    if bg is not None:
        w = bg.shape[1]
        y_addr = int(extension['hip_addr_y'])
        y_imp = int(extension['hip_impact_y'])
        hip_imp_pt = _ipt(posture['hip_impact_px'])
        cv2.line(bg, (0, y_addr), (w, y_addr), (255, 255, 255), 1, cv2.LINE_AA)
        cv2.putText(bg, 'address hip level', (w - 190, y_addr - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
        cv2.circle(bg, (hip_imp_pt[0], y_imp), 7, (0, 165, 255), -1)   # impact hip
        _draw_verdict_text(bg, [
            f'Pelvis rise {extension["rise"]:+.2f} torso-len',
            f'threshold {extension["threshold"]:.2f}  ->  '
            f'{"EARLY EXTENSION" if extension["flagged"] else "OK"}',
        ], extension['flagged'])
        cv2.imwrite(EXTENSION_OUTPUT, bg)

    # ---- Visual: loss of posture (impact spine vs address spine angle) ----
    bg = _read_frame(phases['impact'])
    if bg is not None:
        hip_imp = posture['hip_impact_px']
        sh_imp = posture['sh_impact_px']
        # Address spine direction, anchored at the impact hip for angle comparison
        addr_vec = (posture['sh_addr_px'][0] - posture['hip_addr_px'][0],
                    posture['sh_addr_px'][1] - posture['hip_addr_px'][1])
        ref_end = (hip_imp[0] + addr_vec[0], hip_imp[1] + addr_vec[1])
        cv2.line(bg, _ipt(hip_imp), _ipt(ref_end), (200, 200, 200), 2, cv2.LINE_AA)  # address angle
        cv2.line(bg, _ipt(hip_imp), _ipt(sh_imp), (255, 200, 0), 3, cv2.LINE_AA)     # impact spine
        cv2.circle(bg, _ipt(hip_imp), 6, (255, 0, 255), -1)
        _draw_verdict_text(bg, [
            f'Spine {posture["tilt_addr"]:.0f}->{posture["tilt_impact"]:.0f} deg '
            f'(up {posture["straighten"]:+.0f})',
            f'threshold {posture["threshold"]:.0f} deg  ->  '
            f'{"LOSS OF POSTURE" if posture["flagged"] else "OK"}',
        ], posture['flagged'])
        cv2.imwrite(POSTURE_OUTPUT, bg)

    print(f"\nSaved visuals: {HEAD_OUTPUT}, {PIVOT_OUTPUT}, {EXTENSION_OUTPUT}, {POSTURE_OUTPUT}")


if __name__ == '__main__':
    main()
