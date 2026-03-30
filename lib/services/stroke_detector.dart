import 'dart:math' as math;

class StrokeUpdate {
  final double rateSpm; // strokes/min over the window
  final int strokesInWindow;
  final int totalStrokes;

  const StrokeUpdate(this.rateSpm, this.strokesInWindow, this.totalStrokes);
}

/// Windowed, adaptive-threshold peak detector on acceleration magnitude |a|.
class StrokeDetector {
  StrokeDetector({
    this.windowSec = 5.0,
    this.minPeakDistanceSec = 0.58,
    this.smoothingAlpha = 0.2,
    this.baselineAlpha = 0.05,
    this.thresholdMin = 0.4,
    this.thresholdK = 1.0,
    this.warmupSec = 1.0,
  });

  final double windowSec;
  final double minPeakDistanceSec;
  final double smoothingAlpha; // EMA for |a|
  final double baselineAlpha; // EMA for baseline (slow)
  final double thresholdMin; // absolute floor
  final double thresholdK; // adaptive factor on baseline
  final double warmupSec;

  double? _firstT;
  double? _ema; // smoothed |a|
  double? _baseline; // smoothed baseline
  double? _lastPeakT;
  int _totalStrokes = 0;

  // Recent peak times within [now - windowSec, now]
  final List<double> _peaks = [];

  // For 3-sample local maximum: m(t-2), m(t-1)
  double? _mm1, _m0;

  StrokeUpdate addSample({required double tSec, required double accelMag}) {
    _firstT ??= tSec;

    // Smooth current magnitude
    _ema = (_ema == null)
        ? accelMag
        : (smoothingAlpha * accelMag + (1 - smoothingAlpha) * _ema!);

    // Track baseline slowly
    _baseline = (_baseline == null)
        ? accelMag
        : (baselineAlpha * accelMag + (1 - baselineAlpha) * _baseline!);

    final m1 = _mm1; // t-2
    final m0 = _m0; // t-1
    final m = _ema; // t

    final base = _baseline ?? accelMag;
    final threshold = math.max(thresholdMin, base * thresholdK);
    final warmed = (_firstT != null) ? (tSec - _firstT!) >= warmupSec : false;

    if (warmed && m1 != null && m0 != null && m != null) {
      final isLocalMax = (m0 > m1) && (m0 > m);
      if (isLocalMax && m0 > threshold) {
        final peakT = tSec;
        final okDistance =
            _lastPeakT == null || (peakT - _lastPeakT!) >= minPeakDistanceSec;

        if (okDistance) {
          _peaks.add(peakT);
          _lastPeakT = peakT;
          _totalStrokes++;
        } else {
          // Keep the latest within refractory window
          if (_peaks.isNotEmpty) {
            _peaks[_peaks.length - 1] = peakT;
            _lastPeakT = peakT;
          }
        }
      }
    }

    // Shift history for next step
    _mm1 = _m0;
    _m0 = _ema;

    // Keep only peaks within the active window
    _peaks.removeWhere((pt) => (tSec - pt) > windowSec);

    final strokesInWindow = _peaks.length;
    final rateSpm = strokesInWindow > 0
        ? (strokesInWindow / windowSec) * 60.0
        : 0.0;

    return StrokeUpdate(rateSpm, strokesInWindow, _totalStrokes);
  }

  void reset() {
    _firstT = null;
    _ema = null;
    _baseline = null;
    _lastPeakT = null;
    _mm1 = null;
    _m0 = null;
    _totalStrokes = 0;
    _peaks.clear();
  }
}
