"""Synthetic-landmark characterization tests for src/swing_phases.py.

The lead-wrist trajectory is hand-crafted so the four swing events land at known
frames, then the detected indices and tempo are locked in. Also covers the
fps==0 guard on swing_tempo.
"""
import numpy as np
import pytest

from swing_phases import (detect_phases, implausible_swing, swing_tempo,
                          require_valid_fps, lead_wrist_for, lead_side_for,
                          LEFT_WRIST, RIGHT_WRIST)


def _synthetic_wrist_y():
    """A lead-wrist y trajectory (normalized, y grows downward).

    Low y = wrist high. The shape is: address sit with a dip (takeaway), a climb
    to the top of the backswing (low y), a drop to impact (high y), then a rise
    to the finish.
    """
    return (
        [0.55] * 4 + [0.60]                     # address, dip (takeaway) at 4
        + list(np.linspace(0.58, 0.15, 8))      # climb to top
        + list(np.linspace(0.18, 0.70, 8))      # drop to impact
        + list(np.linspace(0.66, 0.25, 6))      # rise to finish
    )


def test_detect_phases_orders_events():
    phases = detect_phases(_synthetic_wrist_y())
    assert phases == {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    # Events must occur in swing order.
    assert (phases['takeaway'] < phases['top']
            < phases['impact'] < phases['finish'])


def test_detect_phases_tolerates_missing_frames():
    wy = _synthetic_wrist_y()
    wy[15] = float('nan')  # a frame with no detection
    phases = detect_phases(wy)
    assert phases == {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}


def test_detect_phases_returns_none_without_enough_data():
    assert detect_phases([float('nan')] * 10) is None
    assert detect_phases([0.5]) is None


def test_detect_phases_returns_none_when_shorter_than_smooth():
    """A trajectory shorter than the smoothing window cannot be a swing."""
    # At BASELINE_FPS the default smooth is 5, so 4 real frames is too few.
    assert detect_phases([0.5, 0.4, 0.3, 0.6]) is None
    # Empty trajectory
    assert detect_phases([]) is None


def test_swing_tempo_ratio():
    phases = {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    tempo = swing_tempo(phases, fps=30)
    assert tempo['backswing_frames'] == 9
    assert tempo['downswing_frames'] == 8
    assert tempo['ratio'] == pytest.approx(9 / 8)


def test_swing_tempo_none_when_fps_zero():
    """fps==0 must not raise -- swing_tempo returns None."""
    phases = {'takeaway': 3, 'top': 12, 'impact': 20, 'finish': 26}
    assert swing_tempo(phases, fps=0) is None
    assert swing_tempo(phases, fps=None) is None


def test_swing_tempo_none_without_phases():
    assert swing_tempo(None, fps=30) is None


def test_lead_wrist_for_returns_correct_index():
    assert lead_wrist_for('right') == LEFT_WRIST   # lead hand is left for a righty
    assert lead_wrist_for('left') == RIGHT_WRIST   # lead hand is right for a lefty


def test_lead_side_for_returns_correct_label():
    assert lead_side_for('right') == 'Left'
    assert lead_side_for('left') == 'Right'


def test_require_valid_fps_accepts_positive():
    assert require_valid_fps(30, 'x.mp4') == 30.0
    assert require_valid_fps('59.94', 'x.mp4') == pytest.approx(59.94)


@pytest.mark.parametrize('bad', [0, 0.0, -1, float('nan'), float('inf'), None, 'abc'])
def test_require_valid_fps_rejects_invalid(bad):
    """Invalid fps must exit cleanly (SystemExit), not raise ZeroDivision etc."""
    with pytest.raises(SystemExit):
        require_valid_fps(bad, 'missing.mp4')


# --- P1.1: presence gate -----------------------------------------------------
# Found on device 2026-08-17 -- a video of nothing produced a full fault report.
# These cover impossibilities only; none of them encode a calibrated threshold.

def test_implausible_swing_accepts_a_normal_swing():
    # 30 fps, backswing 22 frames, downswing 8 -> ~2.75:1
    phases = {'takeaway': 10, 'top': 32, 'impact': 40, 'finish': 60}
    assert implausible_swing(phases) is None



def test_implausible_swing_rejects_zero_duration_backswing():
    phases = {'takeaway': 5, 'top': 5, 'impact': 20, 'finish': 40}
    assert implausible_swing(phases) is not None


def test_implausible_swing_rejects_zero_duration_downswing():
    phases = {'takeaway': 0, 'top': 20, 'impact': 20, 'finish': 40}
    assert implausible_swing(phases) is not None


def test_implausible_swing_rejects_no_phases():
    assert implausible_swing(None) is not None




# Stance-bounded phases from the first five real recordings off a phone
# (2026-08-17, 30 fps), recomputed through locate_swing with hip_x (the path
# the app and CLI both run). The four genuine swings all have ratio >= 2.78;
# the clip of nothing has ratio 0.29 and is correctly rejected.
#
# These REPLACE the peak-localized fixture DEVICE_PHASES_2026_08_17 that was
# here before the tempo check was reinstated (2026-08-23). That fixture used
# peak localization (0/14 against labels), which put `top` in the first half-
# second and inverted the tempo on all five clips. Peak localization is no
# longer used by any code path (app or CLI use stance-bounded exclusively),
# so the fixture no longer represents what `implausible_swing` receives.
DEVICE_LOCATED_2026_08_17 = [
    # clips 1-4: real swings (ratios 5.00, 2.80, 3.75, 2.78)
    {'takeaway': 239, 'top': 299, 'impact': 311, 'finish': 320},
    {'takeaway': 244, 'top': 272, 'impact': 282, 'finish': 301},
    {'takeaway': 264, 'top': 294, 'impact': 302, 'finish': 312},
    {'takeaway': 316, 'top': 341, 'impact': 350, 'finish': 360},
]


@pytest.mark.parametrize('phases', DEVICE_LOCATED_2026_08_17)
def test_implausible_swing_accepts_real_device_recordings(phases):
    assert implausible_swing(phases) is None


def test_implausible_swing_rejects_nothing_clip():
    """The nothing-clip (clip 0 of device 2026-08-17) has ratio 0.29 under
    stance-bounded localization — correctly rejected by the tempo check."""
    phases = {'takeaway': 106, 'top': 110, 'impact': 124, 'finish': 137}
    reason = implausible_swing(phases)
    assert reason is not None
    assert 'backswing is shorter than the downswing' in reason


# --- P1.4: characterization of locate_swing against real device data ---------
# Pins CURRENT behaviour on the five real recordings so any change to
# locate_swing is visible in a diff. These are NOT assertions that the values
# are correct -- nobody has labelled where the swings actually are. See P1.4.

import os

FIXTURE = os.path.join(os.path.dirname(__file__), 'fixtures',
                       'device_corpus_2026_08_17.jsonl')


def _device_recordings():
    import json
    out = []
    with open(FIXTURE) as fh:
        for line in fh:
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get('record') == 'header':
                continue
            out.append(rec)
    return out


def test_locate_swing_places_events_inside_the_clip():
    """The weakest claim that is actually true: events are ordered and in range.

    Deliberately not pinning frame numbers. The values are unvalidated, and a
    test asserting them would look like evidence they are right.
    """
    from swing_phases import locate_swing
    for rec in _device_recordings():
        frames = rec['frames']
        wrist = [float('nan') if v is None else v for v in frames['wrist_y']]
        torso = [float('nan') if v is None else v for v in frames['torso']]
        phases = locate_swing(wrist, torso, rec['fps'])
        assert phases is not None
        n = len(wrist)
        assert 0 <= phases['takeaway'] <= phases['top'] <= phases['impact'] \
            <= phases['finish'] < n


def test_locate_swing_beats_peak_localization_on_real_clips():
    """The one comparative claim the data does support.

    Peak-based localization put `top` in the first half-second of 15-18 second
    clips (frames 1, 4, 8, 15). Anchoring on the downswing does not.
    """
    from swing_phases import detect_phases, locate_swing
    for rec in _device_recordings()[1:]:  # skip the clip of nothing
        frames = rec['frames']
        wrist = [float('nan') if v is None else v for v in frames['wrist_y']]
        torso = [float('nan') if v is None else v for v in frames['torso']]
        fps = rec['fps']
        peak_top = detect_phases(wrist, fps=fps)['top']
        located_top = locate_swing(wrist, torso, fps)['top']
        # Peak localization lands in the opening seconds of a 15-18 s clip
        # (frames 1, 15, 130, 8 across the four); downswing anchoring lands
        # hundreds of frames later. Assert only the ordering: WHERE the swing
        # truly is remains unlabelled, so "later" is the strongest honest claim.
        assert located_top > peak_top, (
            f'peak_top={peak_top} located_top={located_top}')
