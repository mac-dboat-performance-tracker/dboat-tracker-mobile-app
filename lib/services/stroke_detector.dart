import 'dart:math' as math;

class StrokeUpdate {
  final double rateSpm; // strokes/min over the window
  final int strokesInWindow;
  final int totalStrokes;

  const StrokeUpdate(this.rateSpm, this.strokesInWindow, this.totalStrokes);
}

/// Windowed peak detector on a pre-normalised gyro/accel stroke signal.
///
/// Uses an arm/rearm state machine matching the water-stroke Python reference:
/// - A peak fires only when the detector is *armed*.
/// - After a peak fires the detector *disarms*.
/// - It re-arms once the smoothed signal drops below [thresholdMin] × 0.5.
class StrokeDetector {
  StrokeDetector({
    this.windowSec = 5.0,
    this.minPeakDistanceSec = 0.80,
    this.smoothingAlpha = 0.2,
    this.baselineAlpha = 0.05,
    this.thresholdMin = 0.55,
    this.thresholdK = 1.0,
    this.warmupSec = 1.0,
  });

  final double windowSec;
  final double minPeakDistanceSec;
  final double smoothingAlpha; // EMA for the input signal
  final double
  baselineAlpha; // slow EMA for adaptive baseline (unused in fixed mode)
  final double thresholdMin; // peak detection floor
  final double thresholdK; // adaptive factor on baseline
  final double warmupSec;

  double? _firstT;
  double? _ema;
  double? _baseline;
  double? _lastPeakT;
  int _totalStrokes = 0;
  bool _armed = true; // arm/rearm gate (Python water-stroke logic)

  final List<double> _peaks = [];
  // All-time peak timestamps (never pruned between samples, only on reset).
  final List<double> _allPeakTimes = [];
  double? _mm1, _m0;

  /// All stroke timestamps detected since the last [reset], in chronological order.
  List<double> get allPeakTimes => List.unmodifiable(_allPeakTimes);

  StrokeUpdate addSample({required double tSec, required double accelMag}) {
    _firstT ??= tSec;

    _ema = (_ema == null)
        ? accelMag
        : (smoothingAlpha * accelMag + (1 - smoothingAlpha) * _ema!);

    _baseline = (_baseline == null)
        ? accelMag
        : (baselineAlpha * accelMag + (1 - baselineAlpha) * _baseline!);

    final m1 = _mm1;
    final m0 = _m0;
    final m = _ema;

    final base = _baseline ?? accelMag;
    final threshold = math.max(thresholdMin, base * thresholdK);
    final rearmFloor = thresholdMin * 0.5;
    final warmed = (_firstT != null) ? (tSec - _firstT!) >= warmupSec : false;

    // Re-arm when signal drops back below half the threshold.
    if (!_armed && m != null && m < rearmFloor) {
      _armed = true;
    }

    if (warmed && _armed && m1 != null && m0 != null && m != null) {
      final isLocalMax = (m0 > m1) && (m0 > m);
      if (isLocalMax && m0 > threshold) {
        final okDistance =
            _lastPeakT == null || (tSec - _lastPeakT!) >= minPeakDistanceSec;
        if (okDistance) {
          _peaks.add(tSec);
          _allPeakTimes.add(tSec);
          _lastPeakT = tSec;
          _totalStrokes++;
          _armed = false; // disarm until signal drops back down
        }
      }
    }

    _mm1 = _m0;
    _m0 = _ema;

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
    _armed = true;
    _peaks.clear();
    _allPeakTimes.clear();
  }
}
