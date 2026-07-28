/// The per-frame trajectory arrays a swing was measured from, kept so a stored
/// swing can be re-measured later.
///
/// This is the corpus's raw material. The detectors reduce eight arrays to four
/// numbers and a tempo ratio, and the extracted JPEGs are deleted as soon as
/// analysis finishes (`SwingAnalyzer.analyze`), so without these arrays a stored
/// swing can never be re-run: not at a different threshold, and not — more
/// importantly — at a different *window basis*. The Dart windows are frame
/// counts tuned at 240 fps while phone capture is typically 30, so today's
/// measurements are taken on a basis that P0.2 is expected to change. Keeping
/// the arrays is what makes that change retrospective rather than a reason to
/// throw the corpus away.
///
/// Roughly 10 KB per swing at typical clip lengths.
///
/// Values are in *pixel* coordinates, matching [FrameFeatures]. NaN (no pose
/// detected for that frame) is stored as null, because JSON has no NaN.
library;

import '../models/frame_features.dart';

/// Rounding applied to stored coordinates: 100 = two decimal places. ML Kit
/// reports pixel positions, and two decimals is far finer than any threshold in
/// the pipeline reads, while keeping the JSON roughly half the size of full
/// double precision.
const double _storeScale = 100.0;

double? _store(double v) {
  if (!v.isFinite) return null;
  return (v * _storeScale).round() / _storeScale;
}

List<double?> _storeAll(Iterable<double> values) =>
    [for (final v in values) _store(v)];

List<double?> _readAll(Object? raw) => [
      for (final v in (raw as List<dynamic>? ?? const []))
        (v as num?)?.toDouble()
    ];

/// The eight parallel per-frame arrays, in capture order.
class FrameSeries {
  final List<double?> eyeX;
  final List<double?> eyeY;
  final List<double?> shoulderX;
  final List<double?> shoulderY;
  final List<double?> hipX;
  final List<double?> hipY;
  final List<double?> torso;
  final List<double?> wristY;

  const FrameSeries({
    required this.eyeX,
    required this.eyeY,
    required this.shoulderX,
    required this.shoulderY,
    required this.hipX,
    required this.hipY,
    required this.torso,
    required this.wristY,
  });

  /// Number of frames, taken from the lead-wrist array (the one phase detection
  /// actually runs on).
  int get frameCount => wristY.length;

  factory FrameSeries.fromFeatures(List<FrameFeatures> features) => FrameSeries(
        eyeX: _storeAll(features.map((f) => f.eyeX)),
        eyeY: _storeAll(features.map((f) => f.eyeY)),
        shoulderX: _storeAll(features.map((f) => f.shoulderX)),
        shoulderY: _storeAll(features.map((f) => f.shoulderY)),
        hipX: _storeAll(features.map((f) => f.hipX)),
        hipY: _storeAll(features.map((f) => f.hipY)),
        torso: _storeAll(features.map((f) => f.torso)),
        wristY: _storeAll(features.map((f) => f.wristY)),
      );

  factory FrameSeries.fromJson(Map<String, dynamic> json) => FrameSeries(
        eyeX: _readAll(json['eye_x']),
        eyeY: _readAll(json['eye_y']),
        shoulderX: _readAll(json['shoulder_x']),
        shoulderY: _readAll(json['shoulder_y']),
        hipX: _readAll(json['hip_x']),
        hipY: _readAll(json['hip_y']),
        torso: _readAll(json['torso']),
        wristY: _readAll(json['wrist_y']),
      );

  Map<String, dynamic> toJson() => {
        'eye_x': eyeX,
        'eye_y': eyeY,
        'shoulder_x': shoulderX,
        'shoulder_y': shoulderY,
        'hip_x': hipX,
        'hip_y': hipY,
        'torso': torso,
        'wrist_y': wristY,
      };

  /// Rebuild the detector inputs from stored arrays (null → NaN), so a stored
  /// swing can be fed straight back through `detectPhases` and the four
  /// detectors offline.
  List<FrameFeatures> toFeatures() {
    double at(List<double?> a, int i) =>
        i < a.length ? (a[i] ?? double.nan) : double.nan;
    return [
      for (var i = 0; i < frameCount; i++)
        FrameFeatures(
          eyeX: at(eyeX, i),
          eyeY: at(eyeY, i),
          shoulderX: at(shoulderX, i),
          shoulderY: at(shoulderY, i),
          hipX: at(hipX, i),
          hipY: at(hipY, i),
          torso: at(torso, i),
          wristY: at(wristY, i),
        ),
    ];
  }
}

/// Fraction of frames in which a pose was detected (0..1), or null when there
/// were no frames at all.
///
/// With the source video gone this is the only surviving signal that a stored
/// swing may be untrustworthy — a swing measured through mostly-interpolated
/// frames looks exactly like a clean one once it is reduced to four numbers.
double? poseCoverage(List<FrameFeatures> features) {
  if (features.isEmpty) return null;
  final detected = features.where((f) => f.detected).length;
  return detected / features.length;
}
