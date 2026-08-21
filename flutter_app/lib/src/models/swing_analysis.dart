/// Aggregated result of analyzing one recorded swing: the phases, tempo, the
/// four fault verdicts, and the recommended drills. This is the object the
/// report screen renders.
library;

import '../analysis/faults.dart';
import '../analysis/swing_history.dart';
import '../analysis/swing_phases.dart';
import 'drill.dart';

/// A single fault's measurement plus a human-readable one-line detail, ready for
/// the UI.
///
/// [flagged] means the measurement passed the detector's reference value — not
/// that the fault is confirmed. The badge in the UI carries that hedge
/// ("Possible") so the label itself stays plain.
///
/// [measured] and [reference] are the raw numbers the gauge widget draws — the
/// value that was compared to the threshold and the threshold itself. Both are
/// torso-length fractions except for loss of posture, which is in degrees
/// ([isAngle]). They are optional only because the model predates them; every
/// verdict built by [SwingAnalyzer] populates them.
class FaultVerdict {
  /// One of the fault ids in `faults.dart` (e.g. [faultHeadSway]).
  final String id;

  /// Display label, e.g. "Head sway".
  final String label;
  final bool flagged;

  /// Short human-readable summary of what was measured.
  final String detail;

  /// The absolute value compared to [reference] — what the gauge draws.
  final double? measured;

  /// The reference threshold the measurement is compared against.
  final double? reference;

  /// True when [measured] and [reference] are in degrees (loss of posture);
  /// false for torso-length fractions.
  final bool isAngle;

  const FaultVerdict({
    required this.id,
    required this.label,
    required this.flagged,
    required this.detail,
    this.measured,
    this.reference,
    this.isAngle = false,
  });

  /// Plain label — the badge carries the tentative hedge ("Possible"), so the
  /// title does not need to repeat it.
  String get tentativeLabel => label;
}

class SwingAnalysis {
  final SwingPhases phases;
  final SwingTempo? tempo;
  final double fps;
  final int frameCount;

  /// The four verdicts, always in a stable order (head sway, reverse pivot,
  /// early extension, loss of posture).
  final List<FaultVerdict> faults;

  /// Recommended drills per flagged fault id, each list sorted easiest-first.
  final Map<String, List<Drill>> recommendations;

  /// This swing as a history entry, ready to append to the swing history for
  /// the swing-over-swing progress comparison.
  final SwingSession session;

  /// The fault the golfer chose to work on for this swing (a fault id), or null
  /// for a full swing check. Every detector still runs regardless; this only
  /// marks the report's focus and floats that fault to the top.
  final String? targeting;

  const SwingAnalysis({
    required this.phases,
    required this.tempo,
    required this.fps,
    required this.frameCount,
    required this.faults,
    required this.recommendations,
    required this.session,
    this.targeting,
  });

  bool get anyFlagged => faults.any((f) => f.flagged);

  /// The verdicts with the focus fault (if any) floated to the top; otherwise
  /// the stable report order is preserved.
  List<FaultVerdict> get faultsByFocus => orderByFocus(faults, targeting);
}

/// Reorder [faults] so the golfer's [targeting] fault comes first, keeping every
/// other verdict in its original order. Returns [faults] unchanged when nothing
/// is targeted. Pure so the report ordering stays unit-testable.
List<FaultVerdict> orderByFocus(List<FaultVerdict> faults, String? targeting) {
  if (targeting == null) return faults;
  final focus = <FaultVerdict>[];
  final rest = <FaultVerdict>[];
  for (final f in faults) {
    (f.id == targeting ? focus : rest).add(f);
  }
  return [...focus, ...rest];
}
