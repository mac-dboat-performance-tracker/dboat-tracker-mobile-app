import 'dart:math' as math;

// ── Data types ────────────────────────────────────────────────────────────────

/// One row of the preprocessed signal matrix (mirrors the MATLAB signal[:,0:11]).
/// Column layout: time(s), localAcc(3), globalAcc(3), quaternion(4).
class SignalRow {
  final double timeSec;
  final double localAx, localAy, localAz;
  final double globalAx, globalAy, globalAz;
  final double qw, qx, qy, qz;

  const SignalRow({
    required this.timeSec,
    required this.localAx,
    required this.localAy,
    required this.localAz,
    required this.globalAx,
    required this.globalAy,
    required this.globalAz,
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
  });
}

/// All metrics produced by [PullLengthDetector.process].
class PullLengthResult {
  /// Low-pass filtered, negated local-Z acceleration (peaks detected here).
  final List<double> filteredAccZ;

  /// Values of detected peaks (in [filteredAccZ]).
  final List<double> peakValues;

  /// Sample indices of detected peaks into [filteredAccZ].
  final List<int> peakIndices;

  /// Time (seconds) of each detected stroke peak.
  final List<double> peakTimes;

  /// Pull length (m) per stroke.
  final List<double> pullLengths;

  /// Time between consecutive strokes (s).  Length = peakIndices.length - 1.
  final List<double> timeDiffs;

  /// Per-stroke rate (strokes/s) = 1/timeDiff.
  final List<double> strokeRates;

  final int strokeCount;
  final double meanPullLength;

  /// Mean of per-stroke rates.
  final double meanStrokeRate;

  /// 1 / mean(timeDiffs) — "average stroke rate" in the MATLAB sense.
  final double invMeanTimeDiff;

  const PullLengthResult({
    required this.filteredAccZ,
    required this.peakValues,
    required this.peakIndices,
    required this.peakTimes,
    required this.pullLengths,
    required this.timeDiffs,
    required this.strokeRates,
    required this.strokeCount,
    required this.meanPullLength,
    required this.meanStrokeRate,
    required this.invMeanTimeDiff,
  });

  static const PullLengthResult empty = PullLengthResult(
    filteredAccZ: [],
    peakValues: [],
    peakIndices: [],
    peakTimes: [],
    pullLengths: [],
    timeDiffs: [],
    strokeRates: [],
    strokeCount: 0,
    meanPullLength: 0.0,
    meanStrokeRate: 0.0,
    invMeanTimeDiff: 0.0,
  );
}

// ── Detector ──────────────────────────────────────────────────────────────────

/// Dart port of the MATLAB `preprocess_signal` + `process_signal` pipeline.
///
/// **Preprocessing** (`preprocess`):
///   - SLERP-interpolates quaternions to each acceleration timestamp.
///   - Calibrates local acceleration by applying `conj(q_first)`.
///   - Rotates calibrated acceleration to the global frame via the
///     interpolated quaternion.
///
/// **Processing** (`process`):
///   - Applies a Butterworth low-pass filter to local-Z acceleration.
///   - Detects peaks (strokes) in the negated filtered signal using
///     prominence-based peak finding.
///   - For each stroke interval (between surrounding troughs), double-
///     integrates global acceleration to compute paddle-tip displacement.
///   - Returns per-stroke pull lengths and aggregated session metrics.
///
/// Parameters mirror the trained values the MATLAB script loads from
/// `parameters.mat`.  Reasonable defaults work for typical paddle stroke
/// data sampled at 50–100 Hz.
class PullLengthDetector {
  const PullLengthDetector({
    this.filterOrder = 2,
    this.cutoffRatio = 0.1,
    this.minPeakHeight = 0.1,
    this.minPeakProminence = 0.3,
    this.peakThreshold = 0.0,
    this.minPeakDistanceSec = 0.8,
    this.minPeakWidthSec = 0.0,
    this.maxPeakWidthSec = 5.0,
    this.tipToImu = 1.06,
  });

  /// Butterworth filter order (positive integer, typically 2–4).
  final int filterOrder;

  /// Normalised cutoff frequency in (0, 1) where 1 = Nyquist.
  final double cutoffRatio;

  /// Minimum peak height in the negated filtered acc-Z signal.
  final double minPeakHeight;

  /// Minimum peak prominence (how much the peak stands above surroundings).
  final double minPeakProminence;

  /// Minimum rise above immediately adjacent samples.
  final double peakThreshold;

  /// Minimum time between consecutive detected strokes (seconds).
  final double minPeakDistanceSec;

  /// Minimum stroke peak width at half-prominence level (seconds).
  final double minPeakWidthSec;

  /// Maximum stroke peak width at half-prominence level (seconds).
  final double maxPeakWidthSec;

  /// Distance from the IMU sensor to the paddle tip (metres).
  final double tipToImu;

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Build the preprocessed signal from raw acceleration and rotation timelines.
  ///
  /// [tAcc], [ax], [ay], [az] – acceleration samples already in seconds,
  /// sorted ascending, originating from data_type == 0 rows.
  ///
  /// [tRot], [qw], [qx], [qy], [qz] – rotation samples in seconds, sorted
  /// ascending, originating from data_type == 1 rows.
  ///
  /// Returns one [SignalRow] per acceleration sample that falls inside the
  /// rotation timeline (samples before the first rotation frame are dropped,
  /// matching MATLAB's `valid = ~isnan(lower_idx)` filter).
  List<SignalRow> preprocess({
    required List<double> tAcc,
    required List<double> ax,
    required List<double> ay,
    required List<double> az,
    required List<double> tRot,
    required List<double> qw,
    required List<double> qx,
    required List<double> qy,
    required List<double> qz,
  }) {
    if (tAcc.isEmpty || tRot.isEmpty) return const [];

    final nAcc = tAcc.length;
    final nRot = tRot.length;
    final rows = <SignalRow>[];

    // Calibration quaternion = conjugate of the first rotation sample.
    // Normalise it first.
    final q0 = _qNorm(qw[0], qx[0], qy[0], qz[0]);

    // Two-pointer scan: rotLo is the largest index where tRot[rotLo] <= tAcc[i].
    int rotLo = 0;
    for (int i = 0; i < nAcc; i++) {
      final t = tAcc[i];

      // Skip acc samples that precede the rotation timeline.
      if (t < tRot[0]) continue;

      // Advance lower bracket.
      while (rotLo < nRot - 2 && tRot[rotLo + 1] <= t) {
        rotLo++;
      }

      // Need an upper bracket to interpolate.
      if (rotLo >= nRot - 1) break;

      final t0 = tRot[rotLo];
      final t1 = tRot[rotLo + 1];
      final frac = (t1 > t0) ? ((t - t0) / (t1 - t0)).clamp(0.0, 1.0) : 0.0;

      // Normalise bracket quaternions.
      final qLo = _qNorm(qw[rotLo], qx[rotLo], qy[rotLo], qz[rotLo]);
      final qHi = _qNorm(qw[rotLo + 1], qx[rotLo + 1], qy[rotLo + 1], qz[rotLo + 1]);

      // SLERP to get the interpolated quaternion at this acc timestamp.
      final qi = _qSlerp(qLo, qHi, frac);

      // Step 1 – calibrate local acc: rotate by conj(q_first).
      final cal = _qRotate(q0.cw, q0.cx, q0.cy, q0.cz, ax[i], ay[i], az[i]);

      // Step 2 – rotate to global frame via current quaternion.
      final glo = _qRotate(qi.$1, qi.$2, qi.$3, qi.$4, cal.$1, cal.$2, cal.$3);

      rows.add(SignalRow(
        timeSec: t,
        localAx: ax[i],
        localAy: ay[i],
        localAz: az[i],
        globalAx: glo.$1,
        globalAy: glo.$2,
        globalAz: glo.$3,
        qw: qi.$1,
        qx: qi.$2,
        qy: qi.$3,
        qz: qi.$4,
      ));
    }

    return rows;
  }

  /// Run the full signal-processing pipeline on a preprocessed [signal].
  ///
  /// Applies the Butterworth filter to local-Z, then either:
  /// - Uses [externalPeakTimes] (e.g. from [StrokeDetector.allPeakTimes]) when
  ///   provided — maps each timestamp to the nearest signal index and skips the
  ///   internal `findpeaks` step entirely.
  /// - Falls back to the internal prominence-based peak detector when
  ///   [externalPeakTimes] is null.
  ///
  /// Either way the trough-bounded double-integration for pull length is identical.
  PullLengthResult process(
    List<SignalRow> signal, {
    List<double>? externalPeakTimes,
  }) {
    if (signal.length < 3) return PullLengthResult.empty;

    final n = signal.length;
    final timeS = List<double>.generate(n, (i) => signal[i].timeSec);
    final localAz = List<double>.generate(n, (i) => signal[i].localAz);

    // Design and apply Butterworth LP filter to local-Z acc.
    final (b: filterB, a: filterA) = _butter(filterOrder, cutoffRatio);
    final accZlp = _iirFilter(filterB, filterA, localAz);
    final negAcc = List<double>.generate(n, (i) => -accZlp[i]);

    // ── Peak resolution ────────────────────────────────────────────────────
    final List<int> peakIndices;
    final List<double> peakValues;

    if (externalPeakTimes != null) {
      // Map external timestamps → nearest signal indices, keeping only those
      // that fall within this signal's time range.
      final rawIndices = <int>[];
      for (final pt in externalPeakTimes) {
        if (pt < timeS.first || pt > timeS.last) continue;
        rawIndices.add(_nearestTimeIndex(timeS, pt));
      }
      rawIndices.sort();
      // Deduplicate indices that collapsed to the same sample.
      final unique = <int>[];
      for (final idx in rawIndices) {
        if (unique.isEmpty || unique.last != idx) unique.add(idx);
      }
      peakIndices = unique;
      peakValues = [for (final i in unique) negAcc[i]];
    } else {
      // Internal MATLAB-style findpeaks on the Butterworth-filtered signal.
      final dt = _medianDt(timeS);
      final minDistSamples = math.max(1, (minPeakDistanceSec / dt).round());
      final minWidthSamples =
          minPeakWidthSec > 0 ? (minPeakWidthSec / dt).round() : 0;
      final maxWidthSamples = (maxPeakWidthSec / dt).round();
      final (peakVals: pv, peakIdxs: pi) = _findPeaks(
        negAcc,
        minPeakHeight: minPeakHeight,
        minPeakProminence: minPeakProminence,
        threshold: peakThreshold,
        minPeakDistance: minDistSamples,
        minPeakWidth: minWidthSamples,
        maxPeakWidth: maxWidthSamples,
      );
      peakIndices = pi;
      peakValues = pv;
    }

    final peakTimes = peakIndices.map((i) => timeS[i]).toList();

    if (peakIndices.isEmpty) {
      return PullLengthResult(
        filteredAccZ: negAcc,
        peakValues: const [],
        peakIndices: const [],
        peakTimes: const [],
        pullLengths: const [],
        timeDiffs: const [],
        strokeRates: const [],
        strokeCount: 0,
        meanPullLength: 0.0,
        meanStrokeRate: 0.0,
        invMeanTimeDiff: 0.0,
      );
    }

    // Find troughs in negAcc (= peaks in accZlp) with minimal constraints.
    final (peakVals: _, peakIdxs: troughIndices) = _findPeaks(
      accZlp,
      minPeakHeight: double.negativeInfinity,
      minPeakProminence: 0.0,
      threshold: 0.0,
      minPeakDistance: 1,
      minPeakWidth: 0,
      maxPeakWidth: n,
    );

    // Calibrate the tip coordinate once: apply conj(q_first) to [tipToImu,0,0].
    final q0s = signal[0];
    final tipCalib = _qRotate(
        q0s.qw, -q0s.qx, -q0s.qy, -q0s.qz, tipToImu, 0.0, 0.0);

    // Compute pull length for each detected stroke.
    final pullLengths = List<double>.filled(peakIndices.length, 0.0);

    for (int pi = 0; pi < peakIndices.length; pi++) {
      final peakIdx = peakIndices[pi];

      // Find the nearest trough before and after this peak.
      final (strokeStart: sStart, strokeEnd: sEnd) =
          _strokeBounds(peakIdx, troughIndices, n);

      final len = sEnd - sStart + 1;
      final tInt = List<double>.generate(len, (j) => signal[sStart + j].timeSec);
      final gAxInt = List<double>.generate(len, (j) => signal[sStart + j].globalAx);
      final gAyInt = List<double>.generate(len, (j) => signal[sStart + j].globalAy);
      final gAzInt = List<double>.generate(len, (j) => signal[sStart + j].globalAz);
      final qwInt = List<double>.generate(len, (j) => signal[sStart + j].qw);
      final qxInt = List<double>.generate(len, (j) => signal[sStart + j].qx);
      final qyInt = List<double>.generate(len, (j) => signal[sStart + j].qy);
      final qzInt = List<double>.generate(len, (j) => signal[sStart + j].qz);

      // Velocity via cumulative trapezoidal integration (zero initial velocity).
      final velX = _cumTrapz(tInt, gAxInt);
      final velY = _cumTrapz(tInt, gAyInt);
      final velZ = _cumTrapz(tInt, gAzInt);

      // Position = ∫vel dt + rotated tip offset.
      final posXRel = _cumTrapz(tInt, velX);
      final posYRel = _cumTrapz(tInt, velY);
      final posZRel = _cumTrapz(tInt, velZ);

      final posX = List<double>.filled(len, 0.0);
      final posY = List<double>.filled(len, 0.0);
      final posZ = List<double>.filled(len, 0.0);
      for (int j = 0; j < len; j++) {
        final tip = _qRotate(
            qwInt[j], qxInt[j], qyInt[j], qzInt[j],
            tipCalib.$1, tipCalib.$2, tipCalib.$3);
        posX[j] = posXRel[j] + tip.$1;
        posY[j] = posYRel[j] + tip.$2;
        posZ[j] = posZRel[j] + tip.$3;
      }

      // Pull length = |pos_end - pos_start|.
      final dx = posX.last - posX.first;
      final dy = posY.last - posY.first;
      final dz = posZ.last - posZ.first;
      pullLengths[pi] = math.sqrt(dx * dx + dy * dy + dz * dz);
    }

    // Aggregate stroke metrics.
    final timeDiffs = <double>[];
    for (int i = 1; i < peakTimes.length; i++) {
      timeDiffs.add(peakTimes[i] - peakTimes[i - 1]);
    }

    final strokeRates =
        timeDiffs.map((d) => d > 0.0 ? 1.0 / d : 0.0).toList();

    final meanPullLength = pullLengths.isNotEmpty
        ? pullLengths.reduce((a, b) => a + b) / pullLengths.length
        : 0.0;

    final meanTimeDiff = timeDiffs.isNotEmpty
        ? timeDiffs.reduce((a, b) => a + b) / timeDiffs.length
        : 0.0;

    final meanStrokeRate = strokeRates.isNotEmpty
        ? strokeRates.reduce((a, b) => a + b) / strokeRates.length
        : 0.0;

    return PullLengthResult(
      filteredAccZ: negAcc,
      peakValues: peakValues,
      peakIndices: peakIndices,
      peakTimes: peakTimes,
      pullLengths: pullLengths,
      timeDiffs: timeDiffs,
      strokeRates: strokeRates,
      strokeCount: peakIndices.length,
      meanPullLength: meanPullLength,
      meanStrokeRate: meanStrokeRate,
      invMeanTimeDiff: meanTimeDiff > 0 ? 1.0 / meanTimeDiff : 0.0,
    );
  }

  // ── Stroke boundary helper ────────────────────────────────────────────────

  /// Returns the trough-bounded interval [strokeStart, strokeEnd] for a peak
  /// at [peakIdx], mirroring the MATLAB loop logic exactly.
  ({int strokeStart, int strokeEnd}) _strokeBounds(
      int peakIdx, List<int> troughIndices, int signalLen) {
    if (troughIndices.isEmpty) return (strokeStart: 0, strokeEnd: signalLen - 1);

    // Differences: positive → trough is before peak; negative → after.
    final diffs = troughIndices.map((ti) => peakIdx - ti).toList();

    final posDiffs = diffs.where((d) => d > 0).toList();
    final negDiffs = diffs.where((d) => d < 0).toList();

    int strokeStart;
    int strokeEnd;

    if (posDiffs.isEmpty) {
      strokeStart = 0;
      if (negDiffs.isEmpty) {
        strokeEnd = signalLen - 1;
      } else {
        final maxNeg = negDiffs.reduce(math.max);
        final idx = diffs.indexWhere((d) => d == maxNeg);
        strokeEnd = troughIndices[idx];
      }
    } else {
      final minPos = posDiffs.reduce(math.min);
      final preTroughListIdx = diffs.indexWhere((d) => d == minPos);
      final postTroughListIdx = preTroughListIdx + 1;
      strokeStart = troughIndices[preTroughListIdx];
      strokeEnd = (postTroughListIdx < troughIndices.length)
          ? troughIndices[postTroughListIdx]
          : signalLen - 1;
    }

    return (strokeStart: strokeStart, strokeEnd: strokeEnd);
  }

  // ── Butterworth LP filter design (bilinear transform) ─────────────────────

  /// Designs an [order]-th order Butterworth lowpass filter with normalised
  /// cutoff [Wn] ∈ (0, 1).  Returns (b, a) polynomial coefficients indexed
  /// from z⁰ downward, matching MATLAB's `butter` output convention.
  ({List<double> b, List<double> a}) _butter(int order, double wn) {
    // Bilinear pre-warped analog cutoff.
    final wd = 2.0 * math.tan(math.pi * wn / 2.0);

    var b = [1.0];
    var a = [1.0];

    // One biquad section per conjugate pole pair.
    for (int k = 1; k <= order ~/ 2; k++) {
      final theta = math.pi * (2 * k + order - 1) / (2 * order);
      final reK = math.cos(theta); // real part of analog Butterworth pole
      final wd2 = wd * wd;
      final d0 = 4.0 - 4.0 * reK * wd + wd2;
      final d1 = -8.0 + 2.0 * wd2;
      final d2 = 4.0 + 4.0 * reK * wd + wd2;
      b = _polyConv(b, [wd2 / d0, 2.0 * wd2 / d0, wd2 / d0]);
      a = _polyConv(a, [1.0, d1 / d0, d2 / d0]);
    }

    // Extra first-order section for odd orders.
    if (order.isOdd) {
      final d0 = 2.0 + wd;
      b = _polyConv(b, [wd / d0, wd / d0]);
      a = _polyConv(a, [1.0, (wd - 2.0) / d0]);
    }

    return (b: b, a: a);
  }

  /// Returns the index in [times] whose value is closest to [t].
  /// Assumes [times] is sorted ascending.
  int _nearestTimeIndex(List<double> times, double t) {
    if (times.length == 1) return 0;
    int lo = 0, hi = times.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (t - times[lo]).abs() <= (times[hi] - t).abs() ? lo : hi;
  }

  List<double> _polyConv(List<double> p, List<double> q) {
    final out = List<double>.filled(p.length + q.length - 1, 0.0);
    for (int i = 0; i < p.length; i++) {
      for (int j = 0; j < q.length; j++) {
        out[i + j] += p[i] * q[j];
      }
    }
    return out;
  }

  // ── IIR filter (Direct Form II) ───────────────────────────────────────────

  List<double> _iirFilter(List<double> b, List<double> a, List<double> x) {
    final n = x.length;
    final y = List<double>.filled(n, 0.0);
    final a0 = a[0];
    for (int i = 0; i < n; i++) {
      double yi = 0.0;
      for (int j = 0; j < b.length; j++) {
        if (i - j >= 0) yi += b[j] * x[i - j];
      }
      for (int j = 1; j < a.length; j++) {
        if (i - j >= 0) yi -= a[j] * y[i - j];
      }
      y[i] = yi / a0;
    }
    return y;
  }

  // ── Peak detection ────────────────────────────────────────────────────────

  /// Equivalent of MATLAB's `findpeaks` with prominence, threshold, distance,
  /// and width constraints.
  ({List<double> peakVals, List<int> peakIdxs}) _findPeaks(
    List<double> signal, {
    required double minPeakHeight,
    required double minPeakProminence,
    required double threshold,
    required int minPeakDistance,
    required int minPeakWidth,
    required int maxPeakWidth,
  }) {
    final n = signal.length;
    if (n < 3) return (peakVals: const [], peakIdxs: const []);

    // Step 1 – local maxima.
    final cands = <int>[
      for (int i = 1; i < n - 1; i++)
        if (signal[i] > signal[i - 1] && signal[i] > signal[i + 1]) i,
    ];

    // Step 2 – height.
    var kept = cands.where((i) => signal[i] >= minPeakHeight).toList();

    // Step 3 – threshold (rise above adjacent samples).
    if (threshold > 0) {
      kept = kept
          .where((i) =>
              signal[i] - signal[i - 1] >= threshold &&
              signal[i] - signal[i + 1] >= threshold)
          .toList();
    }

    // Steps 4–5 – prominence and optional width filter.
    final idxOut = <int>[];
    final valOut = <double>[];

    for (final idx in kept) {
      final v = signal[idx];

      // Left minimum up to the first sample that is >= v (or signal start).
      double leftMin = v;
      for (int k = idx - 1; k >= 0; k--) {
        if (signal[k] >= v) break;
        if (signal[k] < leftMin) leftMin = signal[k];
      }

      // Right minimum up to the first sample that is >= v (or signal end).
      double rightMin = v;
      for (int k = idx + 1; k < n; k++) {
        if (signal[k] >= v) break;
        if (signal[k] < rightMin) rightMin = signal[k];
      }

      final prominence = v - math.max(leftMin, rightMin);
      if (prominence < minPeakProminence) continue;

      // Width at half-prominence level.
      if (minPeakWidth > 0 || maxPeakWidth < n) {
        final halfLevel = v - prominence * 0.5;
        final lc = _halfLevelCrossing(signal, idx, halfLevel, goLeft: true);
        final rc = _halfLevelCrossing(signal, idx, halfLevel, goLeft: false);
        final width = rc - lc;
        if (width < minPeakWidth || width > maxPeakWidth) continue;
      }

      idxOut.add(idx);
      valOut.add(v);
    }

    // Step 6 – minimum-distance enforcement: keep tallest peak when two are
    // closer than [minPeakDistance], matching MATLAB's behaviour.
    if (minPeakDistance > 1 && idxOut.isNotEmpty) {
      // Sort by descending value to prefer taller peaks.
      final order = List<int>.generate(idxOut.length, (i) => i)
        ..sort((a, b) => valOut[b].compareTo(valOut[a]));
      final keep = List<bool>.filled(idxOut.length, true);
      for (int i = 0; i < order.length; i++) {
        if (!keep[order[i]]) continue;
        for (int j = i + 1; j < order.length; j++) {
          if (!keep[order[j]]) continue;
          if ((idxOut[order[i]] - idxOut[order[j]]).abs() < minPeakDistance) {
            keep[order[j]] = false;
          }
        }
      }
      // Re-sort survivors by ascending index.
      final sortedOrder = order.where((i) => keep[i]).toList()
        ..sort((a, b) => idxOut[a].compareTo(idxOut[b]));
      return (
        peakVals: [for (final i in sortedOrder) valOut[i]],
        peakIdxs: [for (final i in sortedOrder) idxOut[i]],
      );
    }

    // Already in ascending index order from the linear scan.
    return (peakVals: valOut, peakIdxs: idxOut);
  }

  /// Returns the fractional sample index where [signal] crosses [level] on the
  /// left (if [goLeft]) or right side of [peakIdx].
  double _halfLevelCrossing(
      List<double> signal, int peakIdx, double level,
      {required bool goLeft}) {
    final n = signal.length;
    if (goLeft) {
      for (int k = peakIdx - 1; k >= 0; k--) {
        if (signal[k] <= level) {
          final dv = signal[k + 1] - signal[k];
          return dv.abs() > 1e-12 ? k + (level - signal[k]) / dv : k.toDouble();
        }
      }
      return 0.0;
    } else {
      for (int k = peakIdx + 1; k < n; k++) {
        if (signal[k] <= level) {
          final dv = signal[k] - signal[k - 1];
          return dv.abs() > 1e-12
              ? (k - 1) + (level - signal[k - 1]) / dv
              : k.toDouble();
        }
      }
      return (n - 1).toDouble();
    }
  }

  // ── Integration ───────────────────────────────────────────────────────────

  /// Cumulative trapezoidal integration matching MATLAB's `cumtrapz`.
  List<double> _cumTrapz(List<double> t, List<double> y) {
    final out = List<double>.filled(t.length, 0.0);
    for (int i = 1; i < t.length; i++) {
      out[i] = out[i - 1] + 0.5 * (y[i] + y[i - 1]) * (t[i] - t[i - 1]);
    }
    return out;
  }

  // ── Quaternion helpers ────────────────────────────────────────────────────

  /// Normalise quaternion [w,x,y,z]; returns conjugate fields [cw,cx,cy,cz]
  /// on the record so callers can get both the unit quaternion and its
  /// conjugate in one call.
  _Q0 _qNorm(double w, double x, double y, double z) {
    final n = math.sqrt(w * w + x * x + y * y + z * z);
    if (n > 1e-9) {
      return _Q0(w / n, x / n, y / n, z / n);
    }
    return const _Q0(1.0, 0.0, 0.0, 0.0);
  }

  /// Rotate vector (vx,vy,vz) by unit quaternion (qw,qx,qy,qz).
  /// Uses the optimised Rodrigues formula: v' = v + 2qw(t) + 2(q_v × t)
  /// where t = q_v × v.
  (double, double, double) _qRotate(
      double qw, double qx, double qy, double qz,
      double vx, double vy, double vz) {
    final tx = qy * vz - qz * vy;
    final ty = qz * vx - qx * vz;
    final tz = qx * vy - qy * vx;
    return (
      vx + 2.0 * (qw * tx + qy * tz - qz * ty),
      vy + 2.0 * (qw * ty + qz * tx - qx * tz),
      vz + 2.0 * (qw * tz + qx * ty - qy * tx),
    );
  }

  /// SLERP between two unit quaternions at parameter [t] ∈ [0, 1].
  (double, double, double, double) _qSlerp(
      _Q0 a, _Q0 b, double t) {
    double bw = b.w, bx = b.x, by = b.y, bz = b.z;
    var dot = a.w * bw + a.x * bx + a.y * by + a.z * bz;
    if (dot < 0.0) {
      bw = -bw;
      bx = -bx;
      by = -by;
      bz = -bz;
      dot = -dot;
    }
    dot = dot.clamp(-1.0, 1.0);

    if (dot > 0.9995) {
      // Nearly parallel – use normalised linear interpolation.
      final rw = a.w + t * (bw - a.w);
      final rx = a.x + t * (bx - a.x);
      final ry = a.y + t * (by - a.y);
      final rz = a.z + t * (bz - a.z);
      final n = math.sqrt(rw * rw + rx * rx + ry * ry + rz * rz);
      return n > 1e-9
          ? (rw / n, rx / n, ry / n, rz / n)
          : (1.0, 0.0, 0.0, 0.0);
    }

    final halfTheta = math.acos(dot);
    final sinHT = math.sqrt(1.0 - dot * dot);
    final rA = math.sin((1.0 - t) * halfTheta) / sinHT;
    final rB = math.sin(t * halfTheta) / sinHT;
    return (
      a.w * rA + bw * rB,
      a.x * rA + bx * rB,
      a.y * rA + by * rB,
      a.z * rA + bz * rB,
    );
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  /// Median Δt of a sorted time vector (seconds), clamped to [0.001, 0.5].
  double _medianDt(List<double> t) {
    if (t.length < 2) return 0.02;
    final dts = List<double>.generate(t.length - 1, (i) => t[i + 1] - t[i])
      ..sort();
    return dts[dts.length ~/ 2].clamp(0.001, 0.5);
  }
}

// Internal normalised-quaternion value object.
class _Q0 {
  final double w, x, y, z;
  // Conjugate components (stored directly to avoid allocation in hot path).
  double get cw => w;
  double get cx => -x;
  double get cy => -y;
  double get cz => -z;

  const _Q0(this.w, this.x, this.y, this.z);
}
