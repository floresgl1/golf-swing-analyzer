/// Small numeric helpers that mirror the NumPy operations the Python analyzer
/// relies on. Kept dependency-free so the detection logic is pure Dart and can
/// be unit-tested without Flutter.
///
/// Missing values are represented as [double.nan] (the Python code uses
/// `np.nan` for frames where no pose was detected).
library;

import 'dart:math' as math;

/// Median of the finite values in [values], ignoring NaNs.
///
/// Matches `numpy.nanmedian`: an even count averages the two middle elements,
/// and an all-NaN (or empty) input yields NaN.
double nanMedian(List<double> values) {
  final v = <double>[for (final e in values) if (e.isFinite) e]..sort();
  if (v.isEmpty) return double.nan;
  final n = v.length;
  final mid = n ~/ 2;
  if (n.isOdd) return v[mid];
  return (v[mid - 1] + v[mid]) / 2.0;
}

/// `nanmedian(a[start:end])` with Python-style bounds clamping.
///
/// [end] is exclusive. Indices are clamped into range; an empty slice is NaN.
double nanMedianSlice(List<double> a, int start, int end) {
  final s = start.clamp(0, a.length);
  final e = end.clamp(0, a.length);
  if (s >= e) return double.nan;
  return nanMedian(a.sublist(s, e));
}

/// Replace NaNs by linear interpolation over the finite samples.
///
/// Reproduces `np.interp(idx, idx[good], y[good])`: values before the first
/// finite sample take that sample's value, values after the last take the last
/// sample's value, and gaps in between are linearly interpolated. Requires at
/// least two finite samples.
List<double> fillNaNLinear(List<double> y) {
  final n = y.length;
  final goodIdx = <int>[];
  for (var i = 0; i < n; i++) {
    if (y[i].isFinite) goodIdx.add(i);
  }
  if (goodIdx.length < 2) {
    // Nothing sensible to interpolate from; hand back a copy unchanged.
    return List<double>.from(y);
  }

  final out = List<double>.filled(n, 0.0);
  final first = goodIdx.first;
  final last = goodIdx.last;
  var seg = 0; // index into goodIdx of the left endpoint of the current gap
  for (var i = 0; i < n; i++) {
    if (i <= first) {
      out[i] = y[first];
    } else if (i >= last) {
      out[i] = y[last];
    } else {
      while (goodIdx[seg + 1] < i) {
        seg++;
      }
      final x0 = goodIdx[seg];
      final x1 = goodIdx[seg + 1];
      if (i == x0) {
        out[i] = y[x0];
      } else {
        final t = (i - x0) / (x1 - x0);
        out[i] = y[x0] + t * (y[x1] - y[x0]);
      }
    }
  }
  return out;
}

/// Centered moving average with edge padding, matching the Python
/// `_moving_average`. For an odd window [w], `out[i]` is the mean of
/// `a[i-w//2 .. i+w//2]` with out-of-range indices clamped to the nearest edge
/// (equivalent to NumPy's `np.pad(..., mode='edge')`).
List<double> movingAverageEdge(List<double> a, int w) {
  if (w <= 1) return List<double>.from(a);
  final n = a.length;
  final pad = w ~/ 2;
  final out = List<double>.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    for (var k = i - pad; k <= i + pad; k++) {
      sum += a[k.clamp(0, n - 1)];
    }
    out[i] = sum / w; // w == 2*pad + 1 for the odd windows used here
  }
  return out;
}

/// Index of the first minimum of `a[start:end]` (end exclusive), like
/// `numpy.argmin` which returns the first occurrence.
int argMinSlice(List<double> a, int start, int end) {
  var best = start;
  var bestV = a[start];
  for (var i = start + 1; i < end; i++) {
    if (a[i] < bestV) {
      bestV = a[i];
      best = i;
    }
  }
  return best;
}

/// Index of the first maximum of `a[start:end]` (end exclusive), like
/// `numpy.argmax`.
int argMaxSlice(List<double> a, int start, int end) {
  var best = start;
  var bestV = a[start];
  for (var i = start + 1; i < end; i++) {
    if (a[i] > bestV) {
      bestV = a[i];
      best = i;
    }
  }
  return best;
}

/// Euclidean distance between two points, matching `math.dist`/`math.hypot`.
double hypot(double dx, double dy) => math.sqrt(dx * dx + dy * dy);
