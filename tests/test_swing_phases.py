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


def test_implausible_swing_rejects_the_device_case():
    # The trajectory the app actually reported from a clip containing no swing:
    # backswing 6 frames, downswing 58, ratio 0.1:1.
    phases = {'takeaway': 0, 'top': 6, 'impact': 64, 'finish': 100}
    reason = implausible_swing(phases)
    assert reason is not None
    assert 'downswing' in reason


def test_implausible_swing_rejects_zero_duration_backswing():
    phases = {'takeaway': 5, 'top': 5, 'impact': 20, 'finish': 40}
    assert implausible_swing(phases) is not None


def test_implausible_swing_rejects_zero_duration_downswing():
    phases = {'takeaway': 0, 'top': 20, 'impact': 20, 'finish': 40}
    assert implausible_swing(phases) is not None


def test_implausible_swing_rejects_no_phases():
    assert implausible_swing(None) is not None


def test_implausible_swing_boundary_is_at_the_inversion_point():
    """Equal halves reject; one frame either side of that decides it.

    The gate is deliberately loose -- it rejects only what cannot be a swing,
    not what is merely an odd one. 11:10 is a strange tempo and still passes,
    because judging *how good* a tempo is needs the P0.1 corpus.
    """
    equal = {'takeaway': 0, 'top': 10, 'impact': 20, 'finish': 30}
    assert implausible_swing(equal) is not None

    barely_valid = {'takeaway': 0, 'top': 11, 'impact': 21, 'finish': 30}
    assert implausible_swing(barely_valid) is None
