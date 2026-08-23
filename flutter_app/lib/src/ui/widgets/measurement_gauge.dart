import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A horizontal gauge showing where a measurement sits relative to its
/// reference threshold.
///
/// The gauge draws:
/// - a filled bar from zero to the measured value (amber if flagged, neutral
///   otherwise),
/// - a vertical tick at the reference value,
/// - labels underneath for measured value and reference.
///
/// This is the visual replacement for prose like "0.44 torso-lengths (beta
/// reference 0.13)": uncertainty drawn, not described.
class MeasurementGauge extends StatelessWidget {
  const MeasurementGauge({
    super.key,
    required this.measured,
    required this.reference,
    required this.flagged,
    this.isAngle = false,
  });

  /// The absolute value that was compared against [reference].
  final double measured;

  /// The threshold the measurement is compared against.
  final double reference;

  /// Whether the measurement crossed the reference (flagged).
  final bool flagged;

  /// True when both values are in degrees; false for unitless ratios.
  final bool isAngle;

  @override
  Widget build(BuildContext context) {
    final absM = measured.abs();
    final absR = reference.abs();
    if (!absM.isFinite || !absR.isFinite || absR == 0) {
      return const SizedBox.shrink();
    }

    // Scale the gauge so the larger value sits at ~70% of the track width,
    // leaving headroom for overshoots while keeping the reference tick visible.
    final ceiling = (absM > absR ? absM : absR) * 1.45;
    final measuredFrac = (absM / ceiling).clamp(0.0, 1.0);
    final refFrac = (absR / ceiling).clamp(0.0, 1.0);

    final sc = SwingColors.of(context);
    final statusColor = flagged ? sc.flagged : sc.notSeen;
    final outlineColor = Theme.of(context).colorScheme.outline;
    final unit = isAngle ? '°' : '';

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 14,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Track background.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    // Filled bar to the measured value.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: w * measuredFrac,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    // Reference tick.
                    Positioned(
                      left: (w * refFrac - 1).clamp(0, w - 2),
                      top: -1,
                      bottom: -1,
                      width: 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: outlineColor,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                '${_fmtVal(absM, isAngle)}$unit',
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              Text(
                'threshold ${_fmtVal(absR, isAngle)}$unit',
                style: TextStyle(
                  color: outlineColor,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmtVal(double v, bool isAngle) {
    if (!v.isFinite) return '—';
    return isAngle ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }
}
