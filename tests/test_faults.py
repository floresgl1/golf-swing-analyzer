"""Synthetic-landmark characterization tests for the four fault detectors.

Each detector is driven with hand-crafted per-frame arrays whose medians over
the address/impact/top windows are set so the measured metric lands a hair below
or above the detector's own threshold. For every fault we assert:
  * an input just below threshold does NOT flag,
  * an input just above threshold DOES flag,
and separately that a clean swing flags none of the four.

The thresholds themselves are imported from src/faults.py -- these tests read
them, they do not hard-code or change them.
"""
import numpy as np
import pytest

import faults as F
from faults import (SWAY_THRESHOLD, REVERSE_PIVOT_THRESHOLD,
                    EARLY_EXTENSION_THRESHOLD, POSTURE_THRESHOLD)

# A fixed set of phase indices used by every case below.
PHASES = {'takeaway': 10, 'top': 20, 'impact': 30, 'finish': 40}
N = 45
SCALE = 100.0  # torso length; metrics are value / torso, so this makes them %


def _const(v):
    return [float(v)] * N


def _with_windows(base, windows):
    """A length-N array set to `base`, overriding index ranges from `windows`.

    `windows` maps (lo, hi) inclusive index ranges to a constant value.
    """
    a = [float(base)] * N
    for (lo, hi), val in windows.items():
        for i in range(lo, hi + 1):
            a[i] = float(val)
    return a


TORSO = _const(SCALE)

# The detectors read medians over these windows (see faults.py):
#   address:      [takeaway-10 .. takeaway]     -> [0 .. 10]
#   impact (r=2): [impact-2 .. impact+2]        -> [28 .. 32]
#   impact (r=3): [impact-3 .. impact+3]        -> [27 .. 33]
#   top    (r=3): [top-3 .. top+3]              -> [17 .. 23]


# ---- head sway: lateral = |impact_x - addr_x| / torso ----

def _head(impact_head_x):
    head_x = _with_windows(0.0, {(28, 32): impact_head_x})
    head_y = _const(50.0)  # no vertical dip
    return F.detect_head_movement(head_x, head_y, TORSO, PHASES)


def test_head_sway_just_below_threshold_not_flagged():
    below = (SWAY_THRESHOLD - 0.01) * SCALE  # 0.12 * 100
    res = _head(below)
    assert res['lateral'] == pytest.approx(SWAY_THRESHOLD - 0.01)
    assert not res['flagged']


def test_head_sway_just_above_threshold_flagged():
    above = (SWAY_THRESHOLD + 0.01) * SCALE  # 0.14 * 100
    res = _head(above)
    assert res['lateral'] == pytest.approx(SWAY_THRESHOLD + 0.01)
    assert res['flagged']


# ---- reverse pivot: reverse = ((head_top-hip_top)-(head_addr-hip_addr))*sign/torso ----

def _reverse(head_top_x):
    head_x = _with_windows(0.0, {(17, 23): head_top_x})
    head_y = _const(50.0)
    hip_x = _const(0.0)     # hips stay put -> target_sign = +1, hip terms cancel
    hip_y = _const(200.0)
    return F.detect_reverse_pivot(head_x, head_y, hip_x, hip_y, TORSO, PHASES)


def test_reverse_pivot_just_below_threshold_not_flagged():
    below = (REVERSE_PIVOT_THRESHOLD - 0.01) * SCALE  # 0.11 * 100
    res = _reverse(below)
    assert res['reverse'] == pytest.approx(REVERSE_PIVOT_THRESHOLD - 0.01)
    assert not res['flagged']


def test_reverse_pivot_just_above_threshold_flagged():
    above = (REVERSE_PIVOT_THRESHOLD + 0.01) * SCALE  # 0.13 * 100
    res = _reverse(above)
    assert res['reverse'] == pytest.approx(REVERSE_PIVOT_THRESHOLD + 0.01)
    assert res['flagged']


# ---- early extension: rise = (hip_addr_y - hip_impact_y) / torso ----

def _early(hip_impact_y):
    hip_y = _with_windows(SCALE, {(28, 32): hip_impact_y})  # addr y = 100
    return F.detect_early_extension(hip_y, TORSO, PHASES)


def test_early_extension_just_below_threshold_not_flagged():
    # rise = (100 - impact)/100; want rise = threshold - 0.01
    impact = SCALE - (EARLY_EXTENSION_THRESHOLD - 0.01) * SCALE  # 91
    res = _early(impact)
    assert res['rise'] == pytest.approx(EARLY_EXTENSION_THRESHOLD - 0.01)
    assert not res['flagged']


def test_early_extension_just_above_threshold_flagged():
    impact = SCALE - (EARLY_EXTENSION_THRESHOLD + 0.01) * SCALE  # 89
    res = _early(impact)
    assert res['rise'] == pytest.approx(EARLY_EXTENSION_THRESHOLD + 0.01)
    assert res['flagged']


# ---- loss of posture: straighten = tilt_addr - tilt_impact (degrees) ----

def _posture(addr_shoulder_x):
    # hip fixed at (0, 200), shoulder 100 px above it. Address shoulder is offset
    # sideways (a forward spine tilt); impact shoulder is directly above the hip
    # (upright), so straighten = atan2(addr_shoulder_x, 100) - 0.
    sh_x = _with_windows(addr_shoulder_x, {(27, 33): 0.0})
    sh_y = _const(100.0)
    hip_x = _const(0.0)
    hip_y = _const(200.0)
    return F.detect_loss_of_posture(sh_x, sh_y, hip_x, hip_y, PHASES)


def _shoulder_x_for_tilt(deg):
    import math
    return 100.0 * math.tan(math.radians(deg))


def test_loss_of_posture_just_below_threshold_not_flagged():
    res = _posture(_shoulder_x_for_tilt(POSTURE_THRESHOLD - 0.5))  # 11.5 deg
    assert res['straighten'] == pytest.approx(POSTURE_THRESHOLD - 0.5, abs=1e-3)
    assert not res['flagged']


def test_loss_of_posture_just_above_threshold_flagged():
    res = _posture(_shoulder_x_for_tilt(POSTURE_THRESHOLD + 0.5))  # 12.5 deg
    assert res['straighten'] == pytest.approx(POSTURE_THRESHOLD + 0.5, abs=1e-3)
    assert res['flagged']


# ---- a clean swing flags nothing ----

def test_clean_swing_produces_zero_faults():
    """Minimal movement in every metric -> none of the four detectors flag."""
    head_x = _const(0.0)
    head_y = _const(50.0)
    hip_x = _const(0.0)
    hip_y = _const(200.0)
    sh_x = _const(5.0)      # a tiny, constant forward tilt that never changes
    sh_y = _const(100.0)

    head = F.detect_head_movement(head_x, head_y, TORSO, PHASES)
    pivot = F.detect_reverse_pivot(head_x, head_y, hip_x, hip_y, TORSO, PHASES)
    ext = F.detect_early_extension(hip_y, TORSO, PHASES)
    posture = F.detect_loss_of_posture(sh_x, sh_y, hip_x, hip_y, PHASES)

    assert not head['flagged']
    assert not pivot['flagged']
    assert not ext['flagged']
    assert not posture['flagged']


def test_detectors_return_none_without_phases():
    """No phases (undetectable swing) -> detectors return None, not a crash."""
    assert F.detect_head_movement([], [], [], None) is None
    assert F.detect_reverse_pivot([], [], [], [], [], None) is None
    assert F.detect_early_extension([], [], None) is None
    assert F.detect_loss_of_posture([], [], [], [], None) is None
