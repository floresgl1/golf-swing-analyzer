"""Synthetic-landmark boundary tests for the four fault detectors.

Each detector is driven with hand-crafted per-frame arrays whose medians over
the address/impact/top windows put the measured metric on a chosen point of the
number line. For every fault we assert three points:

  * just below the boundary        -> does NOT flag,
  * exactly on the boundary        -> does NOT flag (see convention below),
  * just above the boundary        -> DOES flag,

and separately that a clean swing flags none of the four.

**Every probe below is a fixed absolute number, written out by hand, and the
thresholds are deliberately NOT imported.** This is the whole point of the
file. The previous version computed each probe *from* the constant it was
meant to pin -- `below = (SWAY_THRESHOLD - 0.01) * SCALE` -- so input and
expectation slid together whenever the constant moved. It read as "0.12 does
not flag, 0.14 does" but asserted "threshold - 0.01 does not flag,
threshold + 0.01 does", which is true by construction for *any* threshold,
including a badly wrong one. All four constants were mutated at once, by up to
3x, and the entire 81-test suite stayed green. See P0.4 in ROADMAP.md.

So: when a threshold moves, these tests go red. **That failure is the
feature.** Do not repair it by re-deriving the probes from the constants. A
human reads the new behaviour, decides it is right, and edits the numbers here
deliberately. The comment beside each probe names the threshold it straddles
so the intent survives; the code does not read it.

**Boundary convention: a value landing exactly on a threshold falls on the
no-action side.** Every verdict comparison in `src/faults.py` is strict (`>`),
so a metric exactly at its threshold is specified as not flagged. Nothing
tested that before -- the boundary is the one input where a strict-vs-inclusive
slip is invisible to the whole suite -- which is why the equality cases are
here. All four probe values divide exactly in IEEE double (13/100, 12/100,
10/100, and atan2/degrees round-tripping 12.0), so the equality tests compare
exact values, not near-misses.
"""
import math

import numpy as np
import pytest

import faults as F

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


# Each detector below is probed with a table of absolute values straddling its
# boundary. The tables carry, in order: a value clearly below, the boundary
# itself, a value a hair above, and a value clearly above.
#
# The two "above" probes exist because a fixed probe only catches a threshold
# that moves *past* it, and the two directions are not symmetric:
#
#   * ANY downward move is caught immediately by the on-boundary probe -- the
#     boundary value starts flagging. Verified down to one ULP.
#   * An upward move is only caught once it clears the nearest above-probe. The
#     clearly-above probe alone left a blind band of a full 0.01 (sway 0.13 ->
#     0.135 stayed green); the hair-above probe shrinks that band to 0.0001.
#
# It is not zero and cannot be: probe spacing IS the resolution. What the suite
# guarantees is that the boundary sits within 0.0001 of where these numbers say
# it does -- a bound the previous version did not have at any size.
#
# One degenerate case survives, recorded so it is not rediscovered as a bug: a
# threshold moved to land EXACTLY on a probe value may or may not be caught,
# because whether the computed metric compares greater than it is then decided
# by floating-point rounding in the detector's own arithmetic. Measured: moving
# EARLY_EXTENSION_THRESHOLD to 0.1001, or DIP_THRESHOLD to 0.2501 -- in each
# case exactly the hair-above probe -- stays green, while the same move on the
# other three goes red. Anywhere off a probe value, the bound above holds.


# ---- head sway: lateral = |impact_x - addr_x| / torso ----
# Straddles SWAY_THRESHOLD, currently 0.13.

def _head(impact_head_x):
    head_x = _with_windows(0.0, {(28, 32): impact_head_x})
    head_y = _const(50.0)  # no vertical dip
    return F.detect_head_movement(head_x, head_y, TORSO, PHASES)


@pytest.mark.parametrize('head_x_px, lateral, flagged', [
    (12.0,   0.12,   False),  # clearly below
    (13.0,   0.13,   False),  # exactly the boundary -> no-action side
    (13.01,  0.1301, True),   # a hair above
    (14.0,   0.14,   True),   # clearly above
])
def test_head_sway_boundary(head_x_px, lateral, flagged):
    res = _head(head_x_px)
    assert res['lateral'] == pytest.approx(lateral)
    # bool(): three of the four detectors return a numpy bool, one a Python bool.
    assert bool(res['flagged']) is flagged


# ---- head dip: vertical = |impact_y - addr_y| / torso ----
# Straddles DIP_THRESHOLD, currently 0.25. `dip_flagged` had NO boundary test
# of any kind before 2026-08-19 -- the fifth threshold in src/faults.py, and
# the only one the suite never touched. It is informational rather than a
# verdict (`flagged` keys on sway alone), but it is still printed, so a wrong
# constant is still a wrong claim shown to a golfer.

def _dip(impact_head_y):
    head_x = _const(0.0)  # no lateral sway
    head_y = _with_windows(50.0, {(28, 32): impact_head_y})
    return F.detect_head_movement(head_x, head_y, TORSO, PHASES)


@pytest.mark.parametrize('head_y_px, vertical, dip_flagged', [
    (74.0,   0.24,   False),  # clearly below (addr y = 50)
    (75.0,   0.25,   False),  # exactly the boundary -> no-action side
    (75.01,  0.2501, True),   # a hair above
    (76.0,   0.26,   True),   # clearly above
])
def test_head_dip_boundary(head_y_px, vertical, dip_flagged):
    res = _dip(head_y_px)
    assert res['vertical'] == pytest.approx(vertical)
    assert bool(res['dip_flagged']) is dip_flagged
    # The head-movement FAULT keys on sway alone, so a dip never flags it.
    assert not res['flagged']


# ---- reverse pivot: reverse = ((head_top-hip_top)-(head_addr-hip_addr))*sign/torso ----
# Straddles REVERSE_PIVOT_THRESHOLD, currently 0.12.

def _reverse(head_top_x):
    head_x = _with_windows(0.0, {(17, 23): head_top_x})
    head_y = _const(50.0)
    hip_x = _const(0.0)     # hips stay put -> target_sign = +1, hip terms cancel
    hip_y = _const(200.0)
    return F.detect_reverse_pivot(head_x, head_y, hip_x, hip_y, TORSO, PHASES)


@pytest.mark.parametrize('head_top_x_px, reverse, flagged', [
    (11.0,   0.11,   False),  # clearly below
    (12.0,   0.12,   False),  # exactly the boundary -> no-action side
    (12.01,  0.1201, True),   # a hair above
    (13.0,   0.13,   True),   # clearly above
])
def test_reverse_pivot_boundary(head_top_x_px, reverse, flagged):
    res = _reverse(head_top_x_px)
    assert res['reverse'] == pytest.approx(reverse)
    # bool(): three of the four detectors return a numpy bool, one a Python bool.
    assert bool(res['flagged']) is flagged


# ---- early extension: rise = (hip_addr_y - hip_impact_y) / torso ----
# Straddles EARLY_EXTENSION_THRESHOLD, currently 0.10. Address hip y is 100, so
# an impact hip y of 90 is a rise of 0.10 torso-lengths -- note the probes run
# DOWNWARD here, because a smaller impact y is a larger rise.

def _early(hip_impact_y):
    hip_y = _with_windows(SCALE, {(28, 32): hip_impact_y})  # addr y = 100
    return F.detect_early_extension(hip_y, TORSO, PHASES)


@pytest.mark.parametrize('hip_impact_y_px, rise, flagged', [
    (91.0,   0.09,   False),  # clearly below
    (90.0,   0.10,   False),  # exactly the boundary -> no-action side
    (89.99,  0.1001, True),   # a hair above
    (89.0,   0.11,   True),   # clearly above
])
def test_early_extension_boundary(hip_impact_y_px, rise, flagged):
    res = _early(hip_impact_y_px)
    assert res['rise'] == pytest.approx(rise)
    # bool(): three of the four detectors return a numpy bool, one a Python bool.
    assert bool(res['flagged']) is flagged


# ---- loss of posture: straighten = tilt_addr - tilt_impact (degrees) ----
# Straddles POSTURE_THRESHOLD, currently 12.0 degrees.

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
    """Address shoulder offset producing a spine tilt of `deg` degrees.

    A coordinate constructor, not a threshold reference: every caller passes a
    literal. `degrees(atan2(_shoulder_x_for_tilt(d), 100)) == d` exactly at
    d = 12.0, which is what makes the on-boundary case an exact comparison.
    """
    return 100.0 * math.tan(math.radians(deg))


@pytest.mark.parametrize('tilt_deg, flagged', [
    (11.5,   False),  # clearly below
    (12.0,   False),  # exactly the boundary -> no-action side
    (12.001, True),   # a hair above
    (12.5,   True),   # clearly above
])
def test_loss_of_posture_boundary(tilt_deg, flagged):
    res = _posture(_shoulder_x_for_tilt(tilt_deg))
    assert res['straighten'] == pytest.approx(tilt_deg, abs=1e-6)
    # bool(): three of the four detectors return a numpy bool, one a Python bool.
    assert bool(res['flagged']) is flagged


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
