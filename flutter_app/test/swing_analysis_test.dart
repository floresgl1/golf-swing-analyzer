import 'package:flutter_test/flutter_test.dart';
import 'package:golf_swing_analyzer/src/analysis/faults.dart';
import 'package:golf_swing_analyzer/src/models/swing_analysis.dart';

/// The four verdicts in the stable report order the analyzer emits.
List<FaultVerdict> _verdicts() => const [
      FaultVerdict(
          id: faultHeadSway, label: 'Head sway', flagged: true, detail: ''),
      FaultVerdict(
          id: faultReversePivot,
          label: 'Reverse pivot',
          flagged: false,
          detail: ''),
      FaultVerdict(
          id: faultEarlyExtension,
          label: 'Early extension',
          flagged: false,
          detail: ''),
      FaultVerdict(
          id: faultLossOfPosture,
          label: 'Loss of posture',
          flagged: false,
          detail: ''),
    ];

void main() {
  group('orderByFocus', () {
    test('no target keeps the stable report order', () {
      final faults = _verdicts();
      expect(orderByFocus(faults, null), same(faults));
      expect(orderByFocus(faults, null).map((f) => f.id).toList(), [
        faultHeadSway,
        faultReversePivot,
        faultEarlyExtension,
        faultLossOfPosture,
      ]);
    });

    test('floats the targeted fault to the top, keeping the rest in order', () {
      final ordered = orderByFocus(_verdicts(), faultEarlyExtension);
      expect(ordered.map((f) => f.id).toList(), [
        faultEarlyExtension, // focus first
        faultHeadSway,
        faultReversePivot,
        faultLossOfPosture,
      ]);
    });

    test('an already-first target leaves the order unchanged', () {
      final ordered = orderByFocus(_verdicts(), faultHeadSway);
      expect(ordered.map((f) => f.id).toList(), [
        faultHeadSway,
        faultReversePivot,
        faultEarlyExtension,
        faultLossOfPosture,
      ]);
    });

    test('an unknown target id leaves every verdict in place', () {
      final ordered = orderByFocus(_verdicts(), 'not_a_fault');
      expect(ordered.map((f) => f.id).toList(), [
        faultHeadSway,
        faultReversePivot,
        faultEarlyExtension,
        faultLossOfPosture,
      ]);
    });
  });
}
