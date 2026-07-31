"""Decision-boundary scaffold for the four fault detectors in src/faults.py.

SCAFFOLDING ONLY -- NO ASSERTION VALUES ARE FILLED IN.

Why this file contains no captured values
-----------------------------------------
This suite exists to protect a threshold recalibration. That makes
characterization capture the wrong tool: capturing what the detectors return
today would pin the CURRENT constants' output, and a pinned threshold test no
longer sits on the decision boundary -- it passes whether or not the detector
still discriminates correctly. The boundary inputs below must therefore be
placed by a human, deliberately, at the value where the verdict is supposed to
flip.

All four detectors use a STRICT `>` against their threshold:
    faults.py:113  'sway_flagged': lateral > sway_threshold,
    faults.py:144  'flagged': reverse > threshold,
    faults.py:169  'flagged': rise > threshold,
    faults.py:193  'flagged': (tilt_addr - tilt_impact) > threshold,
so a metric landing EXACTLY on the threshold is specified to be NOT flagged.
That exact-equality case is what this file targets; the +/- offset cases are
already covered by tests/test_faults.py and are not duplicated here.

Complementary to tests/test_faults.py -- nothing there is modified or replaced.
"""
import math

import pytest

import faults as F
from faults import (SWAY_THRESHOLD, REVERSE_PIVOT_THRESHOLD,
                    EARLY_EXTENSION_THRESHOLD, POSTURE_THRESHOLD)


# --------------------------------------------------------------------------
# Sentinel: every unfilled slot below. Tests fail loudly rather than silently
# passing (or silently exercising a detector with a placeholder input).
# --------------------------------------------------------------------------
class _Todo:
    def __repr__(self):
        return '<TODO(human)>'


TODO = _Todo()


def _require_human(**slots):
    """Fail with a precise message if any boundary/expected slot is unfilled."""
    missing = [name for name, val in slots.items() if isinstance(val, _Todo)]
    if missing:
        pytest.fail(
            'TODO(human): supply ' + ', '.join(sorted(missing)) +
            '. Place the synthetic landmark ON the decision boundary yourself; '
            'do not let it be captured from current behavior.'
        )


# --------------------------------------------------------------------------
# Fixed swing geometry, matching the window arithmetic in faults.py.
#
#   address window : _addr_median   -> [takeaway-10 .. takeaway]  = [0 .. 10]
#   impact  (r=2)  : IMPACT_RADIUS_S -> [impact-2 .. impact+2]    = [28 .. 32]
#   impact  (r=3)  : DEFAULT_RADIUS_S -> [impact-3 .. impact+3]   = [27 .. 33]
#   top     (r=3)  : DEFAULT_RADIUS_S -> [top-3 .. top+3]         = [17 .. 23]
# --------------------------------------------------------------------------
PHASES = {'takeaway': 10, 'top': 20, 'impact': 30, 'finish': 40}
N = 45
SCALE = 100.0  # torso length in px; metrics are value/torso, so this reads as %

ADDRESS_WINDOW = (0, 10)
IMPACT_WINDOW_R2 = (28, 32)
IMPACT_WINDOW_R3 = (27, 33)
TOP_WINDOW = (17, 23)


@pytest.fixture
def phases():
    """Phase indices shared by every boundary case in this module."""
    return dict(PHASES)


@pytest.fixture
def torso():
    """Constant torso length; normalizes every fraction-of-torso metric."""
    return [SCALE] * N


def _const(v):
    return [float(v)] * N


def _with_window(base, window, val):
    """Length-N series at `base`, overridden to `val` across an inclusive range."""
    a = [float(base)] * N
    lo, hi = window
    for i in range(lo, hi + 1):
        a[i] = float(val)
    return a


def _shoulder_x_for_tilt(deg):
    """Horizontal shoulder offset giving `deg` of spine tilt over a 100px spine.

    Mechanical inverse of _spine_tilt (faults.py:77) -- a unit conversion, not a
    chosen boundary value. The DEGREES you pass in are the human decision.
    """
    return 100.0 * math.tan(math.radians(deg))


# --------------------------------------------------------------------------
# Head sway -- detect_head_movement, faults.py:84
#   lateral = |impact_x - addr_x| / torso        (faults.py:107)
#   flagged = lateral > sway_threshold           (faults.py:115)
# NOTE: there is no detect_head_sway(); sway is the 'flagged' key of
# detect_head_movement, with lateral drift as its metric.
# --------------------------------------------------------------------------
def _run_head(impact_head_x, torso):
    head_x = _with_window(0.0, IMPACT_WINDOW_R2, impact_head_x)
    head_y = _const(50.0)  # flat vertical -> dip stays out of the way
    return F.detect_head_movement(head_x, head_y, torso, PHASES)


@pytest.mark.parametrize('case_id, impact_head_x, expected_lateral, expected_flagged', [
    pytest.param(
        'sway_exactly_at_threshold',
        TODO,  # TODO(human): impact head x (px) putting lateral EXACTLY on SWAY_THRESHOLD
        TODO,  # TODO(human): expected 'lateral'
        TODO,  # TODO(human): expected 'flagged' at exact equality (strict > says False)
        id='at-threshold',
    ),
    pytest.param(
        'sway_one_step_past_threshold',
        TODO,  # TODO(human): impact head x (px) one deliberate step PAST SWAY_THRESHOLD
        TODO,  # TODO(human): expected 'lateral'
        TODO,  # TODO(human): expected 'flagged'
        id='past-threshold',
    ),
])
def test_head_sway_boundary(case_id, impact_head_x, expected_lateral,
                            expected_flagged, torso):
    """Head sway flips verdict exactly where SWAY_THRESHOLD says it should.

    Drives lateral drift to a human-placed boundary value and pins both the
    measured metric and the verdict, so a recalibration that moves the constant
    without moving the boundary is caught.
    """
    _require_human(impact_head_x=impact_head_x,
                   expected_lateral=expected_lateral,
                   expected_flagged=expected_flagged)
    res = _run_head(impact_head_x, torso)
    assert res['sway_threshold'] == SWAY_THRESHOLD
    assert res['lateral'] == pytest.approx(expected_lateral)
    assert res['flagged'] is expected_flagged
    assert res['sway_flagged'] is expected_flagged


# --------------------------------------------------------------------------
# Reverse pivot -- detect_reverse_pivot, faults.py:120
#   reverse = ((head_top-hip_top) - (head_addr-hip_addr)) * sign / torso
#                                                (faults.py:140-141)
#   flagged = reverse > threshold                (faults.py:144)
# --------------------------------------------------------------------------
def _run_reverse(top_head_x, torso):
    head_x = _with_window(0.0, TOP_WINDOW, top_head_x)
    head_y = _const(50.0)
    hip_x = _const(0.0)    # hips static -> target_sign = +1 and hip terms cancel
    hip_y = _const(200.0)
    return F.detect_reverse_pivot(head_x, head_y, hip_x, hip_y, torso, PHASES)


@pytest.mark.parametrize('case_id, top_head_x, expected_reverse, expected_flagged', [
    pytest.param(
        'pivot_exactly_at_threshold',
        TODO,  # TODO(human): top-of-backswing head x (px) putting reverse EXACTLY on REVERSE_PIVOT_THRESHOLD
        TODO,  # TODO(human): expected 'reverse'
        TODO,  # TODO(human): expected 'flagged' at exact equality
        id='at-threshold',
    ),
    pytest.param(
        'pivot_one_step_past_threshold',
        TODO,  # TODO(human): top-of-backswing head x (px) one step PAST REVERSE_PIVOT_THRESHOLD
        TODO,  # TODO(human): expected 'reverse'
        TODO,  # TODO(human): expected 'flagged'
        id='past-threshold',
    ),
])
def test_reverse_pivot_boundary(case_id, top_head_x, expected_reverse,
                                expected_flagged, torso):
    """Reverse pivot flips verdict exactly at REVERSE_PIVOT_THRESHOLD.

    Hips are held still so target_sign resolves to +1 and the metric reduces to
    pure head lean toward the target; the boundary lean is human-placed.
    """
    _require_human(top_head_x=top_head_x,
                   expected_reverse=expected_reverse,
                   expected_flagged=expected_flagged)
    res = _run_reverse(top_head_x, torso)
    assert res['threshold'] == REVERSE_PIVOT_THRESHOLD
    assert res['target_sign'] == 1.0
    assert res['reverse'] == pytest.approx(expected_reverse)
    assert res['flagged'] is expected_flagged


# --------------------------------------------------------------------------
# Early extension -- detect_early_extension, faults.py:151
#   rise = (hip_addr_y - hip_impact_y) / torso   (faults.py:167)
#   flagged = rise > threshold                   (faults.py:169)
# Screen y grows downward, so a SMALLER impact y means the pelvis rose.
# --------------------------------------------------------------------------
def _run_early(impact_hip_y, torso):
    hip_y = _with_window(SCALE, IMPACT_WINDOW_R2, impact_hip_y)  # address y = SCALE
    return F.detect_early_extension(hip_y, torso, PHASES)


@pytest.mark.parametrize('case_id, impact_hip_y, expected_rise, expected_flagged', [
    pytest.param(
        'extension_exactly_at_threshold',
        TODO,  # TODO(human): impact hip y (px) putting rise EXACTLY on EARLY_EXTENSION_THRESHOLD
        TODO,  # TODO(human): expected 'rise'
        TODO,  # TODO(human): expected 'flagged' at exact equality
        id='at-threshold',
    ),
    pytest.param(
        'extension_one_step_past_threshold',
        TODO,  # TODO(human): impact hip y (px) one step PAST EARLY_EXTENSION_THRESHOLD
        TODO,  # TODO(human): expected 'rise'
        TODO,  # TODO(human): expected 'flagged'
        id='past-threshold',
    ),
])
def test_early_extension_boundary(case_id, impact_hip_y, expected_rise,
                                  expected_flagged, torso):
    """Pelvis rise flips verdict exactly at EARLY_EXTENSION_THRESHOLD.

    Address hip y is held at SCALE, so the human only places the impact hip y
    that puts the rise on the boundary.
    """
    _require_human(impact_hip_y=impact_hip_y,
                   expected_rise=expected_rise,
                   expected_flagged=expected_flagged)
    res = _run_early(impact_hip_y, torso)
    assert res['threshold'] == EARLY_EXTENSION_THRESHOLD
    assert res['rise'] == pytest.approx(expected_rise)
    assert res['flagged'] is expected_flagged


# --------------------------------------------------------------------------
# Loss of posture -- detect_loss_of_posture, faults.py:174
#   straighten = tilt_addr - tilt_impact, degrees (faults.py:192)
#   flagged = straighten > threshold              (faults.py:193)
# --------------------------------------------------------------------------
def _run_posture(address_tilt_deg):
    # Hip fixed at (0, 200) with the shoulder 100px above it. At impact the
    # shoulder is directly over the hip (tilt_impact = 0), so
    # straighten == address_tilt_deg.
    sh_x = _with_window(_shoulder_x_for_tilt(address_tilt_deg),
                        IMPACT_WINDOW_R3, 0.0)
    sh_y = _const(100.0)
    hip_x = _const(0.0)
    hip_y = _const(200.0)
    return F.detect_loss_of_posture(sh_x, sh_y, hip_x, hip_y, PHASES)


@pytest.mark.parametrize('case_id, address_tilt_deg, expected_straighten, expected_flagged', [
    pytest.param(
        'posture_exactly_at_threshold',
        TODO,  # TODO(human): address spine tilt (deg) putting straighten EXACTLY on POSTURE_THRESHOLD
        TODO,  # TODO(human): expected 'straighten'
        TODO,  # TODO(human): expected 'flagged' at exact equality
        id='at-threshold',
    ),
    pytest.param(
        'posture_one_step_past_threshold',
        TODO,  # TODO(human): address spine tilt (deg) one step PAST POSTURE_THRESHOLD
        TODO,  # TODO(human): expected 'straighten'
        TODO,  # TODO(human): expected 'flagged'
        id='past-threshold',
    ),
])
def test_loss_of_posture_boundary(case_id, address_tilt_deg, expected_straighten,
                                  expected_flagged):
    """Spine straightening flips verdict exactly at POSTURE_THRESHOLD.

    Impact posture is upright by construction, so straighten equals the
    human-placed address tilt in degrees.
    """
    _require_human(address_tilt_deg=address_tilt_deg,
                   expected_straighten=expected_straighten,
                   expected_flagged=expected_flagged)
    res = _run_posture(address_tilt_deg)
    assert res['threshold'] == POSTURE_THRESHOLD
    assert res['tilt_impact'] == pytest.approx(0.0, abs=1e-9)
    assert res['straighten'] == pytest.approx(expected_straighten, abs=1e-3)
    assert res['flagged'] is expected_flagged


# --------------------------------------------------------------------------
# Threshold constants are read, never redefined. If a recalibration changes a
# constant, the boundary inputs above must be re-placed BY HAND to match --
# that is the intended forcing function of this file.
# --------------------------------------------------------------------------
def test_threshold_constants_are_the_ones_under_test():
    """Guard: the boundary cases reference live constants, not stale copies."""
    assert F.SWAY_THRESHOLD is SWAY_THRESHOLD
    assert F.REVERSE_PIVOT_THRESHOLD is REVERSE_PIVOT_THRESHOLD
    assert F.EARLY_EXTENSION_THRESHOLD is EARLY_EXTENSION_THRESHOLD
    assert F.POSTURE_THRESHOLD is POSTURE_THRESHOLD
