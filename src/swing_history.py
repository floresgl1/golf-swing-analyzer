"""Track swing sessions over time and report progress between swings.

This is the verification loop: after every analysis run, src/faults.py saves the
measured fault values and tempo ratio to data/swing_history.json, then compares
the new swing against the previous session -- per fault, previous value ->
current value, whether it improved/worsened/stayed put, and whether it crossed
the fault threshold in either direction. A fault that appears for the first
time is called out with a drill to start on.

All four fault metrics measure excess motion, so for every fault a LOWER value
is better. Tempo is judged by distance from the ~3:1 tour benchmark instead.
"""
import json
import logging
import math
import os
from datetime import datetime
from pathlib import Path

from drill_recommender import FAULT_LABELS, recommend_drills

log = logging.getLogger(__name__)

# History lives next to the drill library; resolve from this file's location so
# it works regardless of the caller's current working directory.
HISTORY_PATH = Path(__file__).resolve().parent.parent / 'data' / 'swing_history.json'

# For each fault id: which keys in the detector-result dicts (src/faults.py)
# hold the measured value and its threshold.
FAULT_METRICS = {
    'head_sway': ('lateral', 'sway_threshold'),
    'reverse_pivot': ('reverse', 'threshold'),
    'early_extension': ('rise', 'threshold'),
    'loss_of_posture': ('straighten', 'threshold'),
}

# Per fault: (value format, unit shown in the report, epsilon). Changes smaller
# than epsilon count as "unchanged" -- they are below what the report's own
# rounding can show, so calling them progress would be noise.
FAULT_FORMATS = {
    'head_sway': ('{:.2f}', 'torso-lengths', 0.005),
    'reverse_pivot': ('{:+.2f}', 'torso-lengths', 0.005),
    'early_extension': ('{:+.2f}', 'torso-lengths', 0.005),
    'loss_of_posture': ('{:+.0f}', 'deg', 0.5),
}

# Tempo target: backswing:downswing ratio of the average tour player.
TEMPO_IDEAL = 3.0
TEMPO_EPSILON = 0.05


def _finite_or_none(x):
    """Round a metric for storage; store None when it could not be measured."""
    x = float(x)
    return round(x, 4) if math.isfinite(x) else None


def build_session(fault_report, tempo=None, targeting=None):
    """Convert detector results into a history entry (a plain JSON-able dict).

    `fault_report` maps fault ids to the result dicts the detectors in
    src/faults.py return; `tempo` is swing_phases.swing_tempo() output.
    `targeting` optionally records which fault the golfer was working on.
    """
    faults = {}
    for fault_id, (value_key, threshold_key) in FAULT_METRICS.items():
        result = fault_report.get(fault_id)
        if not result:
            continue
        faults[fault_id] = {
            'value': _finite_or_none(result[value_key]),
            'threshold': float(result[threshold_key]),
            'flagged': bool(result['flagged']),
        }
    ratio = tempo['ratio'] if tempo else float('nan')
    return {
        'timestamp': datetime.now().astimezone().isoformat(timespec='seconds'),
        'faults': faults,
        'tempo_ratio': _finite_or_none(ratio),
        'targeting': targeting,
    }


def _read_history(path):
    """Read the history file into a {'sessions': [...]} dict.

    Returns an empty history when the file does not exist. If the file exists
    but is corrupt (unreadable or malformed JSON, or the wrong shape), it is
    renamed to <name>.corrupt.bak and an empty history is returned, so a
    damaged file never leaves the caller stuck -- the run just starts fresh.
    """
    path = Path(path)
    if not path.exists():
        return {'sessions': []}
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get('sessions'), list):
            raise ValueError("history is not a {'sessions': [...]} object")
    except (OSError, ValueError) as e:
        backup = path.with_suffix(path.suffix + '.corrupt.bak')
        try:
            os.replace(path, backup)
            log.warning("Swing history %s was corrupt (%s) -- moved it to %s "
                        "and started fresh.", path, e, backup)
        except OSError as move_err:
            log.warning("Swing history %s was corrupt (%s) and could not be "
                        "moved aside (%s) -- starting fresh.", path, e, move_err)
        return {'sessions': []}
    return data


def load_sessions(path=HISTORY_PATH):
    """Return the list of stored sessions, oldest first ([] if no history).

    A corrupt history file is backed up and treated as empty (see
    _read_history), so loading never fails on a damaged file.
    """
    return _read_history(path)['sessions']


def save_session(session, path=HISTORY_PATH):
    """Append a session to the history file (creating it if needed).

    The write is atomic: the updated history is written to a temp file in the
    same directory and then os.replace()d onto the real path, so an interrupted
    or failed write can never leave a half-written (corrupt) history behind.
    """
    path = Path(path)
    data = _read_history(path)
    data['sessions'].append(session)

    tmp = path.with_suffix(path.suffix + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.replace(tmp, path)
    return session


def compare_sessions(previous, current):
    """Compare two session entries fault by fault.

    Returns a dict with:
      'faults':       {fault_id: {'previous', 'current', 'delta', 'direction',
                       'crossing', 'flagged', 'threshold'}} where direction is
                       'improved' | 'worsened' | 'unchanged' and crossing is
                       'fixed' (dropped under the threshold), 'new' (crossed
                       over it), or None.
      'tempo':        same shape for the tempo ratio (judged by distance from
                       TEMPO_IDEAL), or None if either session lacks tempo.
      'new_faults':   fault ids flagged now but not in the previous session.
      'fixed_faults': fault ids flagged before but not now.
    """
    faults = {}
    for fault_id in FAULT_METRICS:
        prev = previous.get('faults', {}).get(fault_id)
        curr = current.get('faults', {}).get(fault_id)
        if not prev or not curr:
            continue
        if prev['value'] is None or curr['value'] is None:
            continue  # metric missing in one session -- nothing to compare
        epsilon = FAULT_FORMATS[fault_id][2]
        delta = curr['value'] - prev['value']
        if abs(delta) < epsilon:
            direction = 'unchanged'
        else:
            direction = 'improved' if delta < 0 else 'worsened'
        crossing = None
        if prev['flagged'] and not curr['flagged']:
            crossing = 'fixed'
        elif curr['flagged'] and not prev['flagged']:
            crossing = 'new'
        faults[fault_id] = {
            'previous': prev['value'], 'current': curr['value'], 'delta': delta,
            'direction': direction, 'crossing': crossing,
            'flagged': curr['flagged'], 'threshold': curr['threshold'],
        }

    tempo = None
    prev_ratio, curr_ratio = previous.get('tempo_ratio'), current.get('tempo_ratio')
    if prev_ratio is not None and curr_ratio is not None:
        drift = abs(curr_ratio - TEMPO_IDEAL) - abs(prev_ratio - TEMPO_IDEAL)
        if abs(drift) < TEMPO_EPSILON:
            direction = 'unchanged'
        else:
            direction = 'improved' if drift < 0 else 'worsened'
        tempo = {'previous': prev_ratio, 'current': curr_ratio,
                 'direction': direction}

    return {
        'faults': faults,
        'tempo': tempo,
        'new_faults': [f for f, c in faults.items() if c['crossing'] == 'new'],
        'fixed_faults': [f for f, c in faults.items() if c['crossing'] == 'fixed'],
    }


_DIRECTION_WORDS = {
    'improved': 'improved!',
    'worsened': 'worsened',
    'unchanged': 'unchanged',
}


def print_comparison(previous, current, drills=None):
    """Print a progress report comparing this swing to the previous session.

    Returns the compare_sessions() dict so callers can reuse the analysis.
    """
    comparison = compare_sessions(previous, current)
    focus = previous.get('targeting')

    print("\n=== Progress vs previous swing ===")
    print(f"\nCompared with the session from {previous.get('timestamp', 'unknown')}."
          + (f" You were working on: {FAULT_LABELS.get(focus, focus)}." if focus else ""))

    for fault_id, c in comparison['faults'].items():
        fmt, unit, _ = FAULT_FORMATS[fault_id]
        line = (f"  {FAULT_LABELS[fault_id]}: {fmt.format(c['previous'])} -> "
                f"{fmt.format(c['current'])} {unit} -- "
                f"{_DIRECTION_WORDS[c['direction']]}")
        if c['crossing'] == 'fixed':
            line += f"  (dropped under the {fmt.format(c['threshold'])} threshold -- fault fixed!)"
        elif c['crossing'] == 'new':
            line += f"  (crossed the {fmt.format(c['threshold'])} threshold -- NEW fault)"
        if fault_id == focus:
            line += "  <- your focus"
        print(line)

    if comparison['tempo']:
        t = comparison['tempo']
        judged = {'improved': 'improved (closer to the 3:1 tour benchmark)',
                  'worsened': 'worsened (further from the 3:1 tour benchmark)',
                  'unchanged': 'unchanged'}[t['direction']]
        print(f"  Tempo ratio: {t['previous']:.1f}:1 -> {t['current']:.1f}:1 -- {judged}")

    if comparison['fixed_faults']:
        fixed = ', '.join(FAULT_LABELS[f].lower() for f in comparison['fixed_faults'])
        print(f"\nNice work -- you cleared: {fixed}. Keep the drills in rotation "
              "so it stays fixed.")

    # A brand-new fault gets called out with a drill to start on right away.
    if comparison['new_faults']:
        new_recs = recommend_drills({f: True for f in comparison['new_faults']}, drills)
        for fault_id in comparison['new_faults']:
            print(f"\nNEW fault this session: {FAULT_LABELS[fault_id]} -- it was "
                  "not present in your previous swing.")
            fault_drills = new_recs.get(fault_id, [])
            if fault_drills:
                first = fault_drills[0]
                print(f"  Start with: {first.get('name', first.get('id'))} "
                      f"[{first.get('difficulty', 'unspecified')}] -- "
                      f"{first.get('description', '').strip()}")
            else:
                print("  (No drills in the library for this fault yet -- add one "
                      "to data/drills.json.)")

    if focus and focus in comparison['faults']:
        direction = comparison['faults'][focus]['direction']
        if direction == 'improved':
            print(f"\nYour focus fault ({FAULT_LABELS[focus].lower()}) improved -- "
                  "the practice is paying off!")
        else:
            print(f"\nYour focus fault ({FAULT_LABELS[focus].lower()}) has not "
                  "improved yet -- stick with the drills and re-test.")

    return comparison


if __name__ == '__main__':
    # Demo: compare two synthetic sessions so the module can be run on its own.
    demo_previous = {
        'timestamp': '2026-07-14T18:02:11-06:00',
        'faults': {
            'head_sway': {'value': 0.18, 'threshold': 0.13, 'flagged': True},
            'reverse_pivot': {'value': -0.05, 'threshold': 0.12, 'flagged': False},
            'early_extension': {'value': 0.04, 'threshold': 0.10, 'flagged': False},
            'loss_of_posture': {'value': 5.0, 'threshold': 12.0, 'flagged': False},
        },
        'tempo_ratio': 2.4,
        'targeting': 'head_sway',
    }
    demo_current = {
        'timestamp': '2026-07-21T18:40:00-06:00',
        'faults': {
            'head_sway': {'value': 0.09, 'threshold': 0.13, 'flagged': False},
            'reverse_pivot': {'value': -0.06, 'threshold': 0.12, 'flagged': False},
            'early_extension': {'value': 0.14, 'threshold': 0.10, 'flagged': True},
            'loss_of_posture': {'value': 6.0, 'threshold': 12.0, 'flagged': False},
        },
        'tempo_ratio': 2.9,
        'targeting': None,
    }
    print_comparison(demo_previous, demo_current)
