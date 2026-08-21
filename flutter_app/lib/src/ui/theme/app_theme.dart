import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// App theme — the single visual system for the golf-swing-analyzer.
//
// Dark-only for now. Every color referenced in src/ui/ should come from either
// Theme.of(context).colorScheme or SwingColors.of(context), never from a bare
// Colors.* literal.
// ---------------------------------------------------------------------------

/// The app's dark theme. Used as both `theme` and `darkTheme` in MaterialApp.
final ThemeData appTheme = _buildDarkTheme();

// -- Palette constants ------------------------------------------------------

const _canvas = Color(0xFF0F1518);
const _surface = Color(0xFF1A201E);
const _surfaceElevated = Color(0xFF212825);
const _primary = Color(0xFFC8943D);
const _onPrimary = Color(0xFF0F1518);
const _onSurface = Color(0xFFE8E0D4);
const _secondary = Color(0xFF9B9488);
const _divider = Color(0xFF2A302D);

// -- Theme construction -----------------------------------------------------

ThemeData _buildDarkTheme() {
  final colorScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: _primary,
    onPrimary: _onPrimary,
    secondary: _secondary,
    onSecondary: _onPrimary,
    error: const Color(0xFFCF6679),
    onError: Colors.black, // justified: Material default error contrast pair
    surface: _surface,
    onSurface: _onSurface,
    surfaceContainerHighest: _surfaceElevated,
    outline: _divider,
    shadow: Colors.black, // justified: shadow color is inherently opaque black
  );

  const tabularFigures = [FontFeature.tabularFigures()];

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: _canvas,
    canvasColor: _canvas,
    cardColor: _surface,
    dividerColor: _divider,
    extensions: const <ThemeExtension>[SwingColors._instance],
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontFeatures: tabularFigures,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontFeatures: tabularFigures,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontFeatures: tabularFigures,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontFeatures: tabularFigures,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontFeatures: tabularFigures,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontFeatures: tabularFigures,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// SwingColors — ThemeExtension for domain-specific color slots.
// ---------------------------------------------------------------------------

@immutable
class SwingColors extends ThemeExtension<SwingColors> {
  const SwingColors({
    required this.flagged,
    required this.notSeen,
    required this.focus,
    required this.scrim,
    required this.onScrim,
    required this.drillBeginner,
    required this.drillIntermediate,
    required this.drillAdvanced,
  });

  /// Amber for POSSIBLE fault chips.
  final Color flagged;

  /// Neutral warm gray for NOT SEEN chips.
  final Color notSeen;

  /// Brand gold — the emphasised card for the active focus fault.
  final Color focus;

  /// Camera overlay panel background (canvas hue, translucent).
  final Color scrim;

  /// Text/icons on camera overlays.
  final Color onScrim;

  /// Muted sage green — "Easy" drills.
  final Color drillBeginner;

  /// Close to brand gold — "Some work" drills.
  final Color drillIntermediate;

  /// Warm terracotta — "Challenging" drills.
  final Color drillAdvanced;

  /// Canonical instance used by the theme.
  static const _instance = SwingColors(
    flagged: Color(0xFFF5A623),
    notSeen: Color(0xFF6B7280),
    focus: Color(0xFFC8943D),
    scrim: Color(0xD90F1518), // 85 % opacity
    onScrim: Color(0xFFF0E6D3),
    drillBeginner: Color(0xFF5B8C5A),
    drillIntermediate: Color(0xFFD4A04A),
    drillAdvanced: Color(0xFFC75B3A),
  );

  /// Convenience accessor.
  static SwingColors of(BuildContext context) =>
      Theme.of(context).extension<SwingColors>()!;

  @override
  SwingColors copyWith({
    Color? flagged,
    Color? notSeen,
    Color? focus,
    Color? scrim,
    Color? onScrim,
    Color? drillBeginner,
    Color? drillIntermediate,
    Color? drillAdvanced,
  }) {
    return SwingColors(
      flagged: flagged ?? this.flagged,
      notSeen: notSeen ?? this.notSeen,
      focus: focus ?? this.focus,
      scrim: scrim ?? this.scrim,
      onScrim: onScrim ?? this.onScrim,
      drillBeginner: drillBeginner ?? this.drillBeginner,
      drillIntermediate: drillIntermediate ?? this.drillIntermediate,
      drillAdvanced: drillAdvanced ?? this.drillAdvanced,
    );
  }

  @override
  SwingColors lerp(covariant SwingColors? other, double t) {
    if (other is! SwingColors) return this;
    return SwingColors(
      flagged: Color.lerp(flagged, other.flagged, t)!,
      notSeen: Color.lerp(notSeen, other.notSeen, t)!,
      focus: Color.lerp(focus, other.focus, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      onScrim: Color.lerp(onScrim, other.onScrim, t)!,
      drillBeginner: Color.lerp(drillBeginner, other.drillBeginner, t)!,
      drillIntermediate:
          Color.lerp(drillIntermediate, other.drillIntermediate, t)!,
      drillAdvanced: Color.lerp(drillAdvanced, other.drillAdvanced, t)!,
    );
  }
}

// ---------------------------------------------------------------------------
// Gap — pre-built SizedBox spacing constants.
// ---------------------------------------------------------------------------

/// Spacing constants as pre-built [SizedBox] widgets.
///
/// Vertical (default): [xs], [sm], [md], [lg].
/// Horizontal: [hxs], [hsm], [hmd], [hlg].
class Gap {
  Gap._();

  // Vertical
  static const xs = SizedBox(height: 4);
  static const sm = SizedBox(height: 8);
  static const md = SizedBox(height: 16);
  static const lg = SizedBox(height: 24);

  // Horizontal
  static const hxs = SizedBox(width: 4);
  static const hsm = SizedBox(width: 8);
  static const hmd = SizedBox(width: 16);
  static const hlg = SizedBox(width: 24);
}
