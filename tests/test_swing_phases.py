"""Synthetic-landmark characterization tests for src/swing_phases.py.

The lead-wrist trajectory is hand-crafted so the four swing events land at known
frames, then the detected indices and tempo are locked in. Also covers the
fps==0 guard on swing_tempo.
"""
import numpy as np
import pytest

from swing_phases import (detect_phases, implausible_swing, swing_tempo,
                          require_valid_fps)


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




# Phase indices recomputed from the first five real recordings off a phone
# (2026-08-17, 30 fps). Every one has a tempo ratio below 1:1 -- the detector
# places `top` in the first half-second of a 15-18 second clip -- so the
# tempo-inversion check that used to live in implausible_swing rejected three
# of the four genuine swings. The gate must let all of these through: they are
# badly *analysed*, which is P1.3's problem, not absent.
DEVICE_PHASES_2026_08_17 = [
    {'takeaway': 0, 'top': 4, 'impact': 63, 'finish': 138},    # clip of nothing
    {'takeaway': 0, 'top': 1, 'impact': 443, 'finish': 456},   # real swing
    {'takeaway': 0, 'top': 15, 'impact': 66, 'finish': 412},   # real swing
    {'takeaway': 0, 'top': 130, 'impact': 265, 'finish': 474}, # real swing
    {'takeaway': 0, 'top': 8, 'impact': 526, 'finish': 540},   # real swing
]


@pytest.mark.parametrize('phases', DEVICE_PHASES_2026_08_17)
def test_implausible_swing_accepts_real_device_recordings(phases):
    assert implausible_swing(phases) is None
