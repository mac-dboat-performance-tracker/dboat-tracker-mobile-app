import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:fl_chart/fl_chart.dart';
import '../services/stroke_detector.dart';
import '../services/pull_length_detector.dart';
import 'package:flutter_cube/flutter_cube.dart';
import '../services/paddle_orientation.dart';

class StrokeTestScreen extends StatefulWidget {
  const StrokeTestScreen({super.key});

  @override
  State<StrokeTestScreen> createState() => _StrokeTestScreenState();
}

class _StrokeTestScreenState extends State<StrokeTestScreen> {
  // Fixed orientation offsets to match desired viewing perspective.
  // View lock: start with no fixed tilt; we'll drive only yaw to keep blade vertical by camera/view.
  static const double _kFixedXDeg = 0.0; // rotate X to stand paddle vertical
  static const double _kFixedYDeg = 45.0;
  static const double _kFixedZDeg = 90.0;
  final StrokeDetector _detector = StrokeDetector(
    windowSec: 5.0,
    minPeakDistanceSec: 0.80,
    smoothingAlpha: 0.1,
    baselineAlpha: 0.05,
    thresholdMin: 0.55,
    thresholdK: 1.0,
    warmupSec: 0.5,
  );

  // Pull-length detector — real-time block-by-block analysis.
  final PullLengthDetector _pld = const PullLengthDetector();
  PullLengthResult _pldResult = PullLengthResult.empty;

  // Preprocessed signal rows built once at load time.
  List<SignalRow> _signalRows = [];
  List<double> _signalRowTimes = []; // parallel time vector for binary search

  // How many preprocessed rows have already been included in the last batch.
  int _pldProcessedRowCount = 0;

  // Re-run process() every time this many new signal rows are consumed.
  static const int _pldBlockSize = 20;

  bool _loading = true;
  String? _error;

  // Replay data
  List<double> _t = [];
  List<double> _ax = [], _ay = [], _az = [];
  // Rotation timeline and stroke signal from gyro (Python-equivalent)
  List<double> _tr = [];
  List<double> _qw = [], _qx = [], _qy = [], _qz = [];
  List<double> _strokeT = [];
  List<double> _strokeSig = [];
  // 3D paddle
  Object? _paddleObj;
  PaddleOrientation? _paddleOrientation;

  // Replay state
  Timer? _timer;
  int _i = 0;
  int _n = 0;
  int _t0Ms = 0;
  double _speed = 1.0; // 1x real-time

  // Live metrics
  double _rateSpm = 0.0;
  int _totalStrokes = 0;
  final double _graphWindowSec = 20.0; // match recording graph window
  final List<FlSpot> _spots = []; // |a| over time
  double? _lastGraphMag; // for light smoothing

  @override
  void initState() {
    super.initState();
    _loadCsvFromAssets();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadCsvFromAssets() async {
    try {
      final text = await rootBundle.loadString('assets/data/test.csv');
      final parsed = _parseInterleavedCsv(text);
      _t = parsed.$1;
      _ax = parsed.$2;
      _ay = parsed.$3;
      _az = parsed.$4;
      _tr = parsed.$5;
      _qw = parsed.$6;
      _qx = parsed.$7;
      _qy = parsed.$8;
      _qz = parsed.$9;
      if (_t.isEmpty) throw Exception('No accel rows parsed (data_type == 0).');
      // Build gyro-based stroke signal from rotation rows (if present).
      _buildStrokeSignal();
      // Run MATLAB-equivalent pull-length analysis on the full signal.
      _runPullLengthAnalysis();
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // Returns (tAcc, ax, ay, az, tRot, qw, qx, qy, qz)
  (
    List<double>,
    List<double>,
    List<double>,
    List<double>,
    List<double>,
    List<double>,
    List<double>,
    List<double>,
    List<double>,
  )
  _parseInterleavedCsv(String text) {
    final lines = const LineSplitter()
        .convert(text)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return ([], [], [], [], [], [], [], [], []);

    final header = lines.first
        .toLowerCase()
        .split(',')
        .map((s) => s.trim())
        .toList();
    int idx(String name) => header.indexOf(name);
    final ti = idx('time_us');
    final di = idx('data_type');
    final v1 = idx('value_1');
    final v2 = idx('value_2');
    final v3 = idx('value_3');
    final v4 = idx('value_4');
    if (ti < 0 || di < 0 || v1 < 0 || v2 < 0 || v3 < 0) {
      throw Exception(
        'CSV must include time_us,data_type,value_1,value_2,value_3',
      );
    }

    List<double> tSec = [], ax = [], ay = [], az = [];
    List<double> tRot = [], qw = [], qx = [], qy = [], qz = [];
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(',');
      if (parts.length <= v3) continue;

      final dtype = double.tryParse(parts[di].trim());
      if (dtype == null) continue;

      final tus = double.tryParse(parts[ti].trim());
      if (tus == null) continue;

      if (dtype == 0) {
        final x = double.tryParse(parts[v1].trim());
        final y = double.tryParse(parts[v2].trim());
        final z = double.tryParse(parts[v3].trim());
        if (x == null || y == null || z == null) continue;
        tSec.add(tus / 1e6);
        ax.add(x);
        ay.add(y);
        az.add(z);
      } else if (dtype == 1 && v4 >= 0) {
        final w = double.tryParse(parts[v1].trim());
        final i_ = double.tryParse(parts[v2].trim());
        final j_ = double.tryParse(parts[v3].trim());
        final k_ = double.tryParse(parts[v4].trim());
        if (w == null || i_ == null || j_ == null || k_ == null) continue;
        tRot.add(tus / 1e6);
        qw.add(w);
        qx.add(i_);
        qy.add(j_);
        qz.add(k_);
      }
    }
    if (tSec.isEmpty && tRot.isEmpty)
      return ([], [], [], [], [], [], [], [], []);

    // Normalize BOTH timelines to a COMMON zero so nearest-neighbor works.
    final double t0Common;
    if (tSec.isNotEmpty && tRot.isNotEmpty) {
      t0Common = math.min(tSec.first, tRot.first);
    } else if (tSec.isNotEmpty) {
      t0Common = tSec.first;
    } else {
      t0Common = tRot.first;
    }
    for (var i = 0; i < tSec.length; i++) tSec[i] -= t0Common;
    for (var i = 0; i < tRot.length; i++) tRot[i] -= t0Common;

    // Ensure both timelines are strictly sorted in case source had jitter.
    if (tSec.isNotEmpty) {
      final idxs = List<int>.generate(tSec.length, (i) => i)
        ..sort((a, b) => tSec[a].compareTo(tSec[b]));
      tSec = [for (final i in idxs) tSec[i]];
      ax = [for (final i in idxs) ax[i]];
      ay = [for (final i in idxs) ay[i]];
      az = [for (final i in idxs) az[i]];
    }
    if (tRot.isNotEmpty) {
      final idxs = List<int>.generate(tRot.length, (i) => i)
        ..sort((a, b) => tRot[a].compareTo(tRot[b]));
      tRot = [for (final i in idxs) tRot[i]];
      qw = [for (final i in idxs) qw[i]];
      qx = [for (final i in idxs) qx[i]];
      qy = [for (final i in idxs) qy[i]];
      qz = [for (final i in idxs) qz[i]];
    }
    return (tSec, ax, ay, az, tRot, qw, qx, qy, qz);
  }

  void _buildStrokeSignal() {
    _strokeT = [];
    _strokeSig = [];
    if (_tr.isEmpty) return;

    final n = _tr.length;
    final qw = List<double>.from(_qw),
        qx = List<double>.from(_qx),
        qy = List<double>.from(_qy),
        qz = List<double>.from(_qz);
    for (var i = 0; i < n; i++) {
      final norm = math.sqrt(
        qw[i] * qw[i] + qx[i] * qx[i] + qy[i] * qy[i] + qz[i] * qz[i],
      );
      if (norm > 1e-9) {
        qw[i] /= norm;
        qx[i] /= norm;
        qy[i] /= norm;
        qz[i] /= norm;
      } else {
        qw[i] = 1;
        qx[i] = qy[i] = qz[i] = 0;
      }
      if (i > 0) {
        final dot =
            qw[i - 1] * qw[i] +
            qx[i - 1] * qx[i] +
            qy[i - 1] * qy[i] +
            qz[i - 1] * qz[i];
        if (dot < 0) {
          qw[i] = -qw[i];
          qx[i] = -qx[i];
          qy[i] = -qy[i];
          qz[i] = -qz[i];
        }
      }
    }
    final dt = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      dt[i] = (_tr[i] - _tr[i - 1]).clamp(1e-3, 0.05);
    }
    final gyroMag = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      final w1 = qw[i - 1], x1 = qx[i - 1], y1 = qy[i - 1], z1 = qz[i - 1];
      final w2 = qw[i], x2 = qx[i], y2 = qy[i], z2 = qz[i];
      final wc = w1, xc = -x1, yc = -y1, zc = -z1;
      final dw = wc * w2 - xc * x2 - yc * y2 - zc * z2;
      var dx = wc * x2 + xc * w2 + yc * z2 - zc * y2;
      var dy = wc * y2 - xc * z2 + yc * w2 + zc * x2;
      var dz = wc * z2 + xc * y2 - yc * x2 + zc * w2;
      final dnorm = math.sqrt(dw * dw + dx * dx + dy * dy + dz * dz);
      final ndw = dnorm > 1e-12 ? (dw / dnorm) : dw;
      dx = dnorm > 1e-12 ? dx / dnorm : dx;
      dy = dnorm > 1e-12 ? dy / dnorm : dy;
      dz = dnorm > 1e-12 ? dz / dnorm : dz;
      final wC = ndw.clamp(-1.0, 1.0);
      var angle = 2.0 * math.acos(wC);
      if (angle > math.pi) {
        angle = 2.0 * math.pi - angle;
        dx = -dx;
        dy = -dy;
        dz = -dz;
      }
      final s = math.sqrt(math.max(1e-12, 1.0 - wC * wC));
      if (s < 1e-6 || dt[i] <= 1e-6 || angle <= 1e-9) {
        gyroMag[i] = gyroMag[i - 1];
        continue;
      }
      final ax = dx / s, ay = dy / s, az = dz / s;
      final wx = ax * (angle / dt[i]),
          wy = ay * (angle / dt[i]),
          wz = az * (angle / dt[i]);
      gyroMag[i] = math.sqrt(wx * wx + wy * wy + wz * wz);
    }
    if (n > 1) gyroMag[0] = gyroMag[1];

    // Centered moving-average helper
    List<double> ma(List<double> v, int w) {
      if (w <= 1) return List<double>.from(v);
      final out = List<double>.filled(v.length, 0.0);
      final half = w ~/ 2;
      for (var i = 0; i < v.length; i++) {
        double s = 0.0;
        int cnt = 0;
        for (var j = -half; j <= half; j++) {
          final idx = i + j;
          if (idx >= 0 && idx < v.length) {
            s += v[idx];
            cnt++;
          }
        }
        out[i] = cnt > 0 ? s / cnt : v[i];
      }
      return out;
    }

    // Step 1: MA(15) — water-stroke smooth window
    final gSmooth = ma(gyroMag, 15);

    // Step 2: rolling 3-second min-max normalisation (mirrors Python water script)
    // Estimate median dt to find how many frames ≈ 3 s.
    final dts = List<double>.filled(n, 0.02);
    for (var i = 1; i < n; i++) {
      dts[i] = (_tr[i] - _tr[i - 1]).clamp(1e-3, 0.05);
    }
    final dtSorted = List<double>.from(dts.sublist(1))..sort();
    final medianDt = dtSorted.isNotEmpty
        ? dtSorted[dtSorted.length ~/ 2]
        : 0.02;
    final windowFrames = math.max(10, (3.0 / medianDt).round());
    final half = windowFrames ~/ 2;

    final rollMin = List<double>.filled(n, 0.0);
    final rollMax = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      final from = (i - half).clamp(0, n - 1);
      final to = (i + half).clamp(0, n - 1);
      double mn = gSmooth[from], mx = gSmooth[from];
      for (var j = from + 1; j <= to; j++) {
        if (gSmooth[j] < mn) mn = gSmooth[j];
        if (gSmooth[j] > mx) mx = gSmooth[j];
      }
      rollMin[i] = mn;
      rollMax[i] = mx;
    }

    final rawSig = List<double>.generate(n, (i) {
      return ((gSmooth[i] - rollMin[i]) / (rollMax[i] - rollMin[i] + 1e-9))
          .clamp(0.0, 1.0);
    });

    // Step 3: second MA(5) pass to smooth the normalised signal
    final sig = ma(rawSig, 5);

    // Step 4: noise gate — zero out frames where smoothed gyro is below
    //         2× the 30th-percentile noise floor.
    final gSmoothSorted = List<double>.from(gSmooth)..sort();
    final noiseFloor =
        gSmoothSorted[((gSmoothSorted.length - 1) * 0.30).round().clamp(
          0,
          gSmoothSorted.length - 1,
        )];
    for (var i = 0; i < n; i++) {
      if (gSmooth[i] < noiseFloor * 2.0) sig[i] = 0.0;
    }

    _strokeT = List.from(_tr);
    _strokeSig = sig;
  }

  void _runPullLengthAnalysis() {
    if (_t.isEmpty) return;

    // Preprocess once: SLERP-interpolate quaternions + compute global acc.
    _signalRows = _pld.preprocess(
      tAcc: _t,
      ax: _ax,
      ay: _ay,
      az: _az,
      tRot: _tr,
      qw: _qw,
      qx: _qx,
      qy: _qy,
      qz: _qz,
    );
    _signalRowTimes = _signalRows.map((r) => r.timeSec).toList();
    if (_signalRows.isEmpty) return;

    // Run a filter-only pass (empty peaks) so the chart shows the Butterworth
    // signal as a preview before replay starts.
    _pldResult = _pld.process(_signalRows, externalPeakTimes: const []);
    _pldProcessedRowCount = 0;
  }

  /// Called every timer tick. Re-runs process() on the accumulated signal slice
  /// whenever [_pldBlockSize] new rows have been consumed — identical to the
  /// MATLAB block loop.  Uses the existing [StrokeDetector]'s peaks instead of
  /// the MATLAB findpeaks so detection quality is consistent across the app.
  void _maybePldUpdate(double upToTimeSec) {
    if (_signalRowTimes.isEmpty) return;
    final rowsConsumed = _lowerBound(_signalRowTimes, upToTimeSec + 1e-9);
    if (rowsConsumed == 0) return;
    if (rowsConsumed - _pldProcessedRowCount < _pldBlockSize) return;

    // Only pass peak times that fall within the current accumulated slice.
    final sliceEnd = _signalRowTimes[rowsConsumed - 1];
    final peakTimes = _detector.allPeakTimes
        .where((t) => t <= sliceEnd)
        .toList();

    _pldResult = _pld.process(
      _signalRows.sublist(0, rowsConsumed),
      externalPeakTimes: peakTimes,
    );
    _pldProcessedRowCount = rowsConsumed;
  }

  int _lowerBound(List<double> a, double x) {
    int lo = 0, hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (a[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // No per-screen alignment: handled by PaddleOrientation

  void _startReplay() {
    if (_t.isEmpty) return;
    _timer?.cancel();
    _detector.reset();

    // Reset real-time PLD state so the analysis rebuilds from scratch.
    _pldResult = PullLengthResult.empty;
    _pldProcessedRowCount = 0;

    _i = 0;
    _n = _t.length;
    _t0Ms = DateTime.now().millisecondsSinceEpoch;
    // Build reusable orientation controller
    _paddleOrientation = PaddleOrientation(
      tSec: _tr,
      qw: _qw,
      qx: _qx,
      qy: _qy,
      qz: _qz,
      fixedXDeg: _kFixedXDeg,
      fixedYDeg: _kFixedYDeg,
      fixedZDeg: _kFixedZDeg,
      yawOnly: true,
    );

    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (_i >= _n) {
        _timer?.cancel();
        return;
      }
      final elapsed = (DateTime.now().millisecondsSinceEpoch - _t0Ms) / 1000.0;
      final targetT = elapsed * _speed;

      while (_i < _n && _t[_i] <= targetT) {
        final mag = math.sqrt(
          _ax[_i] * _ax[_i] + _ay[_i] * _ay[_i] + _az[_i] * _az[_i],
        );
        // Drive detector from gyro-based stroke signal if available, else fallback to |a|
        if (_strokeT.isNotEmpty && _strokeSig.isNotEmpty) {
          var j = _lowerBound(_strokeT, _t[_i]);
          if (j > 0 && j < _strokeT.length) {
            final prev = (_t[_i] - _strokeT[j - 1]).abs();
            final next = (_strokeT[j] - _t[_i]).abs();
            if (prev <= next) j = j - 1;
          } else if (j >= _strokeT.length) {
            j = _strokeT.length - 1;
          }
          final sig = _strokeSig[j];
          final upd = _detector.addSample(tSec: _t[_i], accelMag: sig);
          _rateSpm = upd.rateSpm;
          _totalStrokes = upd.totalStrokes;
        } else {
          final upd = _detector.addSample(tSec: _t[_i], accelMag: mag);
          _rateSpm = upd.rateSpm;
          _totalStrokes = upd.totalStrokes;
        }
        // Update graph series
        final smoothed = (_lastGraphMag == null)
            ? mag
            : (_lastGraphMag! + (mag - _lastGraphMag!) * 0.5);
        _lastGraphMag = smoothed;
        _spots.add(FlSpot(_t[_i], smoothed));
        final minVisibleT = targetT - _graphWindowSec;
        while (_spots.isNotEmpty && _spots.first.x < minVisibleT) {
          _spots.removeAt(0);
        }
        // Drive paddle rotation using reusable orientation controller
        if (_paddleObj != null && _paddleOrientation != null) {
          final e = _paddleOrientation!.eulerAt(_t[_i]);
          _paddleObj!.rotation.setValues(e.x, e.y, e.z);
          // Ensure transform is applied this frame
          try {
            _paddleObj!.updateTransform();
          } catch (_) {}
        }
        _i++;
      }

      // Block-by-block pull-length update (mirrors the MATLAB block loop).
      _maybePldUpdate(targetT);

      if (mounted) setState(() {});
      if (_i >= _n) _timer?.cancel();
    });
  }

  void _stopReplay() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stroke Test')),
        body: Center(child: Text('Error: $_error')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stroke Detector Test (CSV Replay)'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Replay controls ──────────────────────────────────────────────
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _startReplay,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _stopReplay,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              const SizedBox(width: 16),
              const Text('Speed:'),
              const SizedBox(width: 8),
              DropdownButton<double>(
                value: _speed,
                items: const [
                  DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                  DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                  DropdownMenuItem(value: 2.0, child: Text('2.0x')),
                ],
                onChanged: (v) => setState(() => _speed = v ?? 1.0),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Live replay metrics ──────────────────────────────────────────
          Row(
            children: [
              _metricCard(
                'Stroke Rate',
                '${_rateSpm.toStringAsFixed(1)} spm',
                Icons.speed,
              ),
              const SizedBox(width: 12),
              _metricCard(
                'Total Strokes',
                '$_totalStrokes',
                Icons.fitness_center,
              ),
              const SizedBox(width: 12),
              _metricCard(
                'Mean Pull Length',
                _pldResult.meanPullLength > 0
                    ? '${_pldResult.meanPullLength.toStringAsFixed(2)} m'
                    : '—',
                Icons.straighten,
                color: Colors.purple.shade700,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Live acceleration magnitude graph (rolling window) ───────────
          _chartCard(child: _buildAccelChart()),
          const SizedBox(height: 16),

          // ── 3D paddle replay ─────────────────────────────────────────────
          _chartCard(
            child: AbsorbPointer(
              absorbing: true,
              child: Cube(
                onSceneCreated: (scene) {
                  scene.camera.zoom = 14;
                  final obj = Object(fileName: 'assets/models/paddle.obj');
                  try {
                    obj.scale.setValues(0.8, 0.8, 0.8);
                  } catch (_) {}
                  scene.world.add(obj);
                  _paddleObj = obj;
                },
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Replay progress label.
          Center(
            child: Text(
              _i < _n
                  ? 't=${_t[_i.clamp(0, _n - 1)].toStringAsFixed(2)}s'
                  : 'Replay finished',
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 24),

          // ── Pull-length analysis (static, whole-signal) ──────────────────
          _buildPullLengthSection(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Pull-length section ──────────────────────────────────────────────────

  Widget _buildPullLengthSection() {
    final r = _pldResult;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.analytics_outlined,
              color: Colors.purple.shade700,
              size: 20,
            ),
            const SizedBox(width: 6),
            Text(
              'Pull-Length Analysis',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.purple.shade700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        if (r.filteredAccZ.isNotEmpty) ...[
          _chartCard(child: _buildPldChart()),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'Filtered −Z acc (blue) · stroke peaks (purple) · pull length (orange)',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
        ] else
          Container(
            height: 80,
            alignment: Alignment.center,
            child: Text(
              _tr.isEmpty
                  ? 'No rotation data — pull-length unavailable'
                  : 'Press Start to begin analysis',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _buildPldChart() {
    final r = _pldResult;
    final sig = r.filteredAccZ;
    final n = sig.length;
    if (n == 0) return const SizedBox.shrink();

    // Downsample for display performance (target ≤1000 points).
    const kMaxPts = 1000;
    final step = math.max(1, n ~/ kMaxPts);

    // Map sample index → time using the acceleration timeline.
    double timeAt(int i) => (i < _t.length) ? _t[i] : i.toDouble();

    final linePts = <FlSpot>[
      for (int i = 0; i < n; i += step) FlSpot(timeAt(i), sig[i]),
    ];

    // Peak markers at detected stroke positions.
    final peakPts = [
      for (int k = 0; k < r.peakIndices.length; k++)
        FlSpot(r.peakTimes[k], r.peakValues[k]),
    ];

    // Pull-length series: one dot per stroke, value scaled to the acc axis.
    // Scale pull lengths so they fit nicely in the chart (Y range ≈ ±max(sig)).
    final maxSig = sig.fold<double>(0.0, (m, v) => v > m ? v : m);
    final maxPl = r.pullLengths.fold<double>(0.01, (m, v) => v > m ? v : m);
    final plScale = maxSig > 0 && maxPl > 0 ? maxSig * 0.8 / maxPl : 1.0;
    final plPts = [
      for (int k = 0; k < r.peakIndices.length; k++)
        FlSpot(r.peakTimes[k], r.pullLengths[k] * plScale),
    ];

    final minX = linePts.first.x;
    final maxX = linePts.last.x;
    final yPad = maxSig * 0.1;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: math.max(0.5, maxSig / 4).roundToDouble(),
          getDrawingHorizontalLine: (v) =>
              FlLine(color: Colors.grey.shade200, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: math.max(1.0, (maxX - minX) / 5).roundToDouble(),
              getTitlesWidget: (v, _) => Text(
                '${v.toStringAsFixed(0)}s',
                style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              interval: math.max(0.5, maxSig / 4).roundToDouble(),
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(1),
                style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey.shade300),
        ),
        minX: minX,
        maxX: maxX,
        minY: -yPad,
        maxY: maxSig + yPad,
        clipData: FlClipData.all(),
        lineBarsData: [
          // Filtered −Z acc (blue line).
          LineChartBarData(
            spots: linePts,
            isCurved: true,
            curveSmoothness: 0.2,
            color: Colors.blue.shade500,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blue.shade500.withValues(alpha: 0.07),
            ),
          ),
          // Pull lengths scaled to the acc axis (orange dots).
          if (plPts.isNotEmpty)
            LineChartBarData(
              spots: plPts,
              isCurved: false,
              color: Colors.orange.shade600,
              barWidth: 0,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, pct, bar, idx) => FlDotCirclePainter(
                  radius: 5,
                  color: Colors.orange.shade600,
                  strokeWidth: 1.5,
                  strokeColor: Colors.white,
                ),
              ),
            ),
          // Peak markers (purple triangles approximated as larger dots).
          if (peakPts.isNotEmpty)
            LineChartBarData(
              spots: peakPts,
              isCurved: false,
              color: Colors.purple.shade600,
              barWidth: 0,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, pct, bar, idx) => FlDotCirclePainter(
                  radius: 4,
                  color: Colors.purple.shade600,
                  strokeWidth: 1.5,
                  strokeColor: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Shared card helpers ──────────────────────────────────────────────────

  Widget _chartCard({required Widget child}) {
    return Container(
      height: 220,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildAccelChart() {
    final double nowT = (_i < _n && _i > 0) ? _t[_i - 1] : 0.0;
    final minX = math.max(0.0, nowT - _graphWindowSec);
    final maxX = minX + _graphWindowSec;
    // Fixed Y range like recording (0 .. 25 m/s²)
    const double minY = 0.0;
    const double maxY = 25.0;

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 5,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: Colors.grey.shade300, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: 4.0,
              getTitlesWidget: (value, meta) => Text(
                '${value.toStringAsFixed(1)}s',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              interval: 5.0,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(0),
                style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
              ),
            ),
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: Colors.grey.shade300),
        ),
        minX: minX,
        maxX: maxX,
        minY: minY,
        maxY: maxY,
        clipData: FlClipData.all(),
        lineBarsData: [
          LineChartBarData(
            spots: _spots
                .where((s) => s.x >= minX && s.x <= maxX)
                .toList(growable: false),
            isCurved: true,
            curveSmoothness: 0.35, // match recording
            color: Colors.blue.shade600,
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blue.shade600.withOpacity(0.10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(
    String title,
    String value,
    IconData icon, {
    Color? color,
  }) {
    final iconColor = color ?? Colors.blue.shade700;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor, size: 18),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
