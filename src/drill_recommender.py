"""Recommend corrective drills for flagged swing faults.

Reads a drill library (data/drills.json) and, given a fault report like the one
produced by src/faults.py, returns and prints the drills that address whichever
faults were flagged. The library is plain JSON so a golf instructor can add or
edit drills without touching any code -- see the notes at the top of
data/drills.json.
"""
import json
import logging
from pathlib import Path

log = logging.getLogger(__name__)

# The library lives next to the code, under the repo's data/ directory. Resolve
# it from this file's location so recommendations work regardless of the caller's
# current working directory.
DRILL_LIBRARY_PATH = Path(__file__).resolve().parent.parent / 'data' / 'drills.json'

# Sort order for recommendations: gentlest first, so a golfer starts with the
# most accessible drill and progresses.
DIFFICULTY_ORDER = {'beginner': 0, 'intermediate': 1, 'advanced': 2}

# Human-friendly names for the fault ids used in the fault report.
FAULT_LABELS = {
    'head_sway': 'Head sway',
    'reverse_pivot': 'Reverse pivot',
    'early_extension': 'Early extension',
    'loss_of_posture': 'Loss of posture',
}


def load_drills(path=DRILL_LIBRARY_PATH):
    """Load the drill library and return the list of drill dicts.

    A missing, unreadable, or malformed library must not take the app down --
    recommendations degrade to "no drills in the library" instead. On any load
    or parse failure this logs a warning and returns an empty list.
    """
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
        drills = data['drills']
        if not isinstance(drills, list):
            raise ValueError("'drills' is not a list")
    except (OSError, ValueError, KeyError, TypeError) as e:
        log.warning("Could not load drill library %s (%s) -- continuing with "
                    "an empty drill list.", path, e)
        return []
    return drills


def flagged_faults(report):
    """Return the fault ids flagged in a fault report dict.

    The report maps a fault id (e.g. 'head_sway') to either a plain boolean or a
    detector result dict carrying a 'flagged' key (as src/faults.py produces).
    Keys that are not known fault ids are ignored, so a full detector report can
    be passed straight through.
    """
    faults = []
    for fault_id, result in report.items():
        if fault_id not in FAULT_LABELS:
            continue
        flagged = result.get('flagged') if isinstance(result, dict) else bool(result)
        if flagged:
            faults.append(fault_id)
    return faults


def recommend_drills(report, drills=None):
    """Return {fault_id: [drills sorted easiest-first]} for every flagged fault.

    Only faults that are flagged in the report appear in the result. Faults with
    no matching drill in the library map to an empty list.
    """
    if drills is None:
        drills = load_drills()
    recommendations = {}
    for fault_id in flagged_faults(report):
        matches = [d for d in drills if d.get('fault') == fault_id]
        matches.sort(key=lambda d: DIFFICULTY_ORDER.get(d.get('difficulty'), 99))
        recommendations[fault_id] = matches
    return recommendations


def _format_drill(drill):
    """Return the printable lines for a single drill."""
    difficulty = drill.get('difficulty', 'unspecified')
    lines = [f"  - {drill.get('name', drill.get('id', 'Unnamed drill'))} "
             f"[{difficulty}]"]
    equipment = (drill.get('equipment') or '').strip()
    if equipment and equipment.lower() != 'none':
        lines.append(f"      Equipment: {equipment}")
    lines.append(f"      {drill.get('description', '').strip()}")
    return lines


def print_recommendations(report, drills=None):
    """Print a coaching-style drill recommendation and return the drill map."""
    recommendations = recommend_drills(report, drills)

    print("\n=== Recommended drills ===")
    if not recommendations:
        print("\nGreat news -- no faults were flagged, so there is nothing to "
              "fix today. Keep grooving that swing!")
        return recommendations

    faults_worded = ', '.join(FAULT_LABELS[f].lower() for f in recommendations)
    print(f"\nI spotted {len(recommendations)} thing(s) to work on: {faults_worded}.")
    print("Here are drills to groove a better move, easiest first:")

    for fault_id, fault_drills in recommendations.items():
        print(f"\n{FAULT_LABELS[fault_id]} -- try these:")
        if not fault_drills:
            print("  (No drills in the library for this fault yet -- add one to "
                  "data/drills.json.)")
            continue
        for drill in fault_drills:
            for line in _format_drill(drill):
                print(line)

    print("\nStart with the beginner drill for each fault, then progress. Work on "
          "one fault at a time for best results.")
    return recommendations


if __name__ == '__main__':
    # Demo with a sample fault report so the module can be run on its own.
    sample_report = {
        'head_sway': {'flagged': True},
        'reverse_pivot': {'flagged': False},
        'early_extension': {'flagged': True},
        'loss_of_posture': {'flagged': False},
    }
    print_recommendations(sample_report)
