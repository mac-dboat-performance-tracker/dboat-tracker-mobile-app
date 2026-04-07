import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/session.dart';
import '../models/paddler.dart';
import '../widgets/force_graph_widget.dart';
import '../widgets/historical_force_graph_widget.dart';
import '../providers/paddler_provider.dart';
import '../providers/ble_provider.dart';
import '../services/csv_logger.dart';
import '../services/session_storage.dart';
import '../services/stroke_detector.dart';
import '../services/pull_length_detector.dart';
import 'video_generation_screen.dart';
import '../services/paddle_orientation.dart';
import 'package:flutter_cube/flutter_cube.dart';
import 'dart:math' show sqrt, acos, pi, pow;
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class SessionScreen extends StatefulWidget {
  final Session session;

  const SessionScreen({super.key, required this.session});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final CSVLogger _csvLogger = CSVLogger();
  final GlobalKey<ForceGraphWidgetState> _forceGraphKey =
      GlobalKey<ForceGraphWidgetState>();

  bool _isConnecting = false;
  bool _isScanning = false;
  final Set<String> _selectedDeviceIds = {};
  DateTime? _sessionStartTime;
  Timer? _durationTimer;
  Map<String, List<AccelDataPoint>>? _historicalData;
  bool _isLoadingHistoricalData = false;
  bool get _isPastSession => widget.session.id != 'session_new';

  // Live stroke metrics
  final StrokeDetector _strokeDetector = StrokeDetector(
    windowSec: 5.0,
    minPeakDistanceSec: 0.80,
    smoothingAlpha: 0.1,
    baselineAlpha: 0.05,
    thresholdMin: 0.55,
    thresholdK: 1.0,
    warmupSec: 0.5,
  );
  double _liveSpm = 0.0;
  int _liveTotalStrokes = 0;
  int? _t0Us;
  bool _strokeCountingEnabled = false;

  // Pull-length detection
  final PullLengthDetector _pld = const PullLengthDetector();
  double _liveMeanPullLength = 0.0;
  double _histAvgAccel = 0.0;

  // Live acc buffer for PLD (accumulates from recording start, cleared on stop)
  final List<double> _pldAccT = [];
  final List<double> _pldAccX = [];
  final List<double> _pldAccY = [];
  final List<double> _pldAccZ = [];
  // Full quat buffer for PLD (no size cap unlike _qt which is for 3D only)
  final List<double> _pldQt = [];
  final List<double> _pldQw = [];
  final List<double> _pldQx = [];
  final List<double> _pldQy = [];
  final List<double> _pldQz = [];
  int _pldAccProcessedCount = 0;
  static const int _pldBlockSize = 20;

  // Historical raw acc components parsed from CSV for PLD preprocessing
  final List<double> _histAccT = [];
  final List<double> _histAccX = [];
  final List<double> _histAccY = [];
  final List<double> _histAccZ = [];

  // Pre-computed per-sample metrics timeline (parallel to _replayStrokeT).
  // Used for fast O(log n) lookup during graph replay.
  List<double> _histTimelineSpm = [];
  List<int> _histTimelineCount = [];
  // Accel magnitude timeline for the first paddler (fast lookup by replay time).
  List<double> _histAccelT = [];
  List<double> _histAccelV = [];

  // Dynamic values shown while the historical graph replays.
  double _dynAccel = 0.0;
  double _dynSpm = 0.0;
  int _dynStrokes = 0;
  double _dynPullLength = 0.0;
  double _livePaddlingForce = 0.0;
  double _dynPseudoForce = 0.0;

  // Per-stroke pull length timeline (from PLD result) for dynamic replay lookup.
  List<double> _histPeakTimes = [];
  List<double> _histPullLengths = [];

  // Live quaternion buffer for 3D (capped rolling window used for gyro signal)
  final List<double> _qt = [];
  final List<double> _qw = [];
  final List<double> _qx = [];
  final List<double> _qy = [];
  final List<double> _qz = [];
  static const int _maxQuatSamples = 512;
  PaddleOrientation? _livePaddle;
  Object? _paddleObj;
  Timer? _renderTimer;
  StreamSubscription<SensorData>? _liveBleSub;

  // Replay quat buffers — used for gyro stroke signal and PLD preprocessing
  final List<double> _rt = [];
  final List<double> _rqw = [];
  final List<double> _rqx = [];
  final List<double> _rqy = [];
  final List<double> _rqz = [];
  PaddleOrientation? _replayPaddle;
  Object? _replayObj;
  Timer? _replayTimer;
  double _replayT = 0.0;
  double _replayTMax = 0.0;

  // Replay gyro-based stroke signal (mirrors test screen's _strokeT/_strokeSig)
  List<double> _replayStrokeT = [];
  List<double> _replayStrokeSig = [];

  // Live gyro-based stroke signal (from quaternions)
  double? _prevQw, _prevQx, _prevQy, _prevQz;
  double? _prevQt; // seconds
  final List<double> _gyroMag = [];
  final int _gyroBufMax = 600;

  @override
  void initState() {
    super.initState();

    // If this is a past session, load historical data
    if (_isPastSession) {
      _loadHistoricalData();
    } else {
      // Sync paddlers from currently connected BLE devices (Paddler 1, 2, 3 by connection order)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final provider = Provider.of<PaddlerProvider>(context, listen: false);
        provider.syncPaddlersFromConnectedDevices();
        _startLiveSubscriptions();
      });
    }
  }

  Future<void> _loadHistoricalData() async {
    setState(() {
      _isLoadingHistoricalData = true;
    });

    try {
      final data = await SessionStorage.loadSessionForceData(widget.session.id);

      if (mounted) {
        setState(() {
          _historicalData = data;
          _isLoadingHistoricalData = false;
        });
      }

      // Initialize replay 3D if CSV is interleaved
      await _initReplayQuaternionsIfAvailable();
    } catch (e) {
      print('Error loading historical data: $e');
      if (mounted) {
        setState(() {
          _isLoadingHistoricalData = false;
        });
        _showError('Error loading session data: $e');
      }
    }
  }

  void _startConnecting() {
    setState(() {
      _isConnecting = true;
      _selectedDeviceIds.clear();
    });
  }

  Future<void> _runScan() async {
    if (!mounted || _isScanning) return;
    setState(() => _isScanning = true);
    try {
      final paddlerProvider = Provider.of<PaddlerProvider>(
        context,
        listen: false,
      );
      await paddlerProvider.scanForDevices();
    } catch (e) {
      _showError('Scan failed: $e');
    }
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _connectSelected() async {
    if (_selectedDeviceIds.isEmpty) {
      _showError('Select at least one device.');
      return;
    }
    try {
      final paddlerProvider = Provider.of<PaddlerProvider>(
        context,
        listen: false,
      );
      await paddlerProvider.connectToSelectedDevices(
        _selectedDeviceIds.toList(),
      );
      _startLiveSubscriptions();
    } catch (e) {
      _showError('Connect failed: $e');
    }
  }

  void _proceedToRecording() {
    final paddlerProvider = Provider.of<PaddlerProvider>(
      context,
      listen: false,
    );

    if (paddlerProvider.paddlers.isEmpty) {
      _showError('No sensors connected. Tap Start to scan and connect.');
      return;
    }

    setState(() {
      _isConnecting = false;
      _sessionStartTime = DateTime.now();
      // Start stroke counting only once the user explicitly starts recording.
      _strokeCountingEnabled = true;
      _liveSpm = 0.0;
      _liveTotalStrokes = 0;
      _livePaddlingForce = 0.0;
    });

    // Reset stroke detection timeline to start at 0 for each recording.
    _strokeDetector.reset();
    _t0Us = null;
    _prevQt = null;
    _prevQw = _prevQx = _prevQy = _prevQz = null;
    _gyroMag.clear();

    // Reset PLD buffers.
    _pldAccT.clear();
    _pldAccX.clear();
    _pldAccY.clear();
    _pldAccZ.clear();
    _pldQt.clear();
    _pldQw.clear();
    _pldQx.clear();
    _pldQy.clear();
    _pldQz.clear();
    _pldAccProcessedCount = 0;
    _liveMeanPullLength = 0.0;

    paddlerProvider.startRecording();
    // Pass a function to get fresh paddler data each time
    _csvLogger.startLogging(
      paddlerProvider.paddlers,
      getPaddlers: () => paddlerProvider.paddlers,
    );

    // Start duration timer
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {});
      } else {
        timer.cancel();
      }
    });

    // Ensure live feed is active
    _startLiveSubscriptions();
  }

  void _cancelConnecting() {
    setState(() {
      _isConnecting = false;
    });
  }

  Future<void> _stopRecording() async {
    final paddlerProvider = Provider.of<PaddlerProvider>(
      context,
      listen: false,
    );

    final sessionName = await _showSessionNameDialog();
    if (sessionName == null || sessionName.trim().isEmpty) {
      return;
    }

    try {
      // Stop all timers first
      _forceGraphKey.currentState?.reset();
      _durationTimer?.cancel();
      _durationTimer = null;

      // IMPORTANT: Stop CSV logging BEFORE stopping recording
      // This ensures all data is written before paddler forces are reset to 0
      await _csvLogger.stopLogging(sessionName: sessionName.trim());

      // Now safe to stop recording and reset paddler data
      paddlerProvider.stopRecording();

      // Reset session state
      if (mounted) {
        setState(() {
          _sessionStartTime = null;
          _isConnecting = false;
          _strokeCountingEnabled = false;
          _liveSpm = 0.0;
          _liveTotalStrokes = 0;
          _livePaddlingForce = 0.0;
        });
      }

      _showSuccess('Session "$sessionName" saved successfully');
    } catch (e) {
      _showError('Error saving session: $e');
    }
  }

  Future<String?> _showSessionNameDialog() async {
    final TextEditingController nameController = TextEditingController();
    final DateTime now = DateTime.now();
    final defaultName =
        'Session_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}';
    nameController.text = defaultName;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Save Session'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter a name for this session:'),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Session Name',
                hintText: 'e.g., Morning Practice',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.of(context).pop(value.trim());
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isNotEmpty) {
                Navigator.of(context).pop(name);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    // Don't save CSV on dispose - only save when user explicitly stops recording
    // _csvLogger.stopLogging(); // Removed to prevent duplicate saves
    _liveBleSub?.cancel();
    _renderTimer?.cancel();
    _replayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Dragon Boat Monitor', style: TextStyle(fontSize: 16)),
            Text(
              widget.session.name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
        ],
      ),
      body: Container(
        color: Colors.grey.shade100,
        child: _isConnecting ? _buildConnectingView() : _buildMainContent(),
      ),
    );
  }

  Widget _buildConnectingView() {
    return Consumer2<BLEProvider, PaddlerProvider>(
      builder: (context, bleProvider, paddlerProvider, child) {
        final scannedEntries = bleProvider.scannedDevices.entries.toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Select sensors for this session',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Only DB_IMU sensors are shown. Scan, check the devices you want, tap Connect selected. You can Disconnect any device before starting. Proceed to start recording (no new devices during recording).',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isScanning ? null : _runScan,
                      icon: _isScanning
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bluetooth_searching),
                      label: Text(
                        _isScanning ? 'Scanning...' : 'Scan for devices',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: scannedEntries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bluetooth_disabled,
                            size: 48,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _isScanning
                                ? 'Scanning...'
                                : 'Tap "Scan for devices" to find sensors',
                            style: TextStyle(color: Colors.grey.shade600),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: scannedEntries.length,
                      itemBuilder: (context, index) {
                        final deviceId = scannedEntries[index].key;
                        final result = scannedEntries[index].value;
                        final name =
                            result.advertisementData.localName.trim().isNotEmpty
                            ? result.advertisementData.localName.trim()
                            : (result.device.platformName.isNotEmpty
                                  ? result.device.platformName
                                  : 'Unknown');
                        final isConnected = bleProvider.isConnected(deviceId);
                        final selected = _selectedDeviceIds.contains(deviceId);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Checkbox(
                              value: selected,
                              onChanged: isConnected
                                  ? null
                                  : (value) {
                                      setState(() {
                                        if (value == true) {
                                          _selectedDeviceIds.add(deviceId);
                                        } else {
                                          _selectedDeviceIds.remove(deviceId);
                                        }
                                      });
                                    },
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              isConnected ? 'Connected' : deviceId,
                              style: TextStyle(
                                fontSize: 12,
                                color: isConnected
                                    ? Colors.green.shade700
                                    : Colors.grey.shade600,
                              ),
                            ),
                            trailing: isConnected
                                ? TextButton.icon(
                                    onPressed: () async {
                                      await bleProvider.disconnect(deviceId);
                                      if (!mounted) return;
                                      final pp = Provider.of<PaddlerProvider>(
                                        context,
                                        listen: false,
                                      );
                                      pp.syncPaddlersFromConnectedDevices();
                                      setState(() {
                                        _selectedDeviceIds.remove(deviceId);
                                      });
                                    },
                                    icon: const Icon(Icons.link_off, size: 18),
                                    label: const Text('Disconnect'),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
            ),
            if (scannedEntries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: ElevatedButton(
                  onPressed: _selectedDeviceIds.isEmpty
                      ? null
                      : _connectSelected,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    'Connect selected (${_selectedDeviceIds.length})',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancelConnecting,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: BorderSide(color: Colors.grey.shade400),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: paddlerProvider.paddlers.isEmpty
                          ? null
                          : _proceedToRecording,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        disabledBackgroundColor: Colors.grey.shade300,
                      ),
                      child: Text(
                        'Proceed (${paddlerProvider.paddlers.length})',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMainContent() {
    if (_isPastSession) {
      if (_isLoadingHistoricalData) {
        return const Center(child: CircularProgressIndicator());
      }

      final duration = widget.session.duration;
      final paddlers = widget.session.paddlers;

      return ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildMetricsSectionForPastSession(duration, paddlers.length),
          const SizedBox(height: 16),
          // 3D video generation
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => VideoGenerationScreen(
                    sessionId: widget.session.id,
                    sessionName: widget.session.name,
                  ),
                ),
              ),
              icon: const Icon(Icons.videocam_outlined),
              label: const Text('Generate 3D Videos'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: BorderSide(color: Colors.blue.shade700),
                foregroundColor: Colors.blue.shade700,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Replay-driven metric cards (update live as graph replays)
          _buildCompactMetricsWrap([
            _buildCompactMetricCard(
              'Accel',
              '${_dynAccel.toStringAsFixed(1)} m/s²',
              Icons.speed,
            ),
            _buildCompactMetricCard(
              'Stroke Rate',
              _dynSpm > 0 ? '${_dynSpm.toStringAsFixed(1)} spm' : '—',
              Icons.fitness_center,
            ),
            _buildCompactMetricCard(
              'Strokes',
              '$_dynStrokes',
              Icons.countertops,
            ),
            _buildCompactMetricCard(
              'Pull Length',
              _dynPullLength > 0
                  ? '${_dynPullLength.toStringAsFixed(2)} m'
                  : '—',
              Icons.straighten,
              iconColor: Colors.purple.shade700,
            ),
            _buildCompactMetricCard(
              'Est. Force',
              '${_dynPseudoForce.toStringAsFixed(1)} N',
              Icons.bolt,
              iconColor: Colors.orange.shade700,
            ),
          ]),
          const SizedBox(height: 16),
          // Acceleration graph — full session width, data fills left-to-right
          _buildSectionCard(
            title: 'Acceleration (m/s²)',
            child: _historicalData != null
                ? HistoricalForceGraphWidget(
                    key: ValueKey('historical_${widget.session.id}'),
                    paddlers: paddlers,
                    historicalData: _historicalData!,
                    onReplayTick: _onHistReplayTick,
                  )
                : const Center(child: Text('No historical data available')),
          ),
          const SizedBox(height: 16),
          // 3D paddle replay (only when quaternion data was recorded)
          if (_replayPaddle != null)
            _buildSectionCard(
              title: 'Paddle Orientation (Replay)',
              child: SizedBox(
                height: 220,
                child: Cube(
                  interactive: false,
                  onSceneCreated: (scene) {
                    scene.camera.zoom = 8;
                    final obj = Object(fileName: 'assets/models/paddle.obj');
                    _replayObj = obj;
                    scene.world.add(obj);
                    _ensureReplayTimer();
                  },
                ),
              ),
            ),
          if (_replayPaddle != null) const SizedBox(height: 16),
        ],
      );
    }

    // Live / active recording session
    return Consumer<PaddlerProvider>(
      builder: (context, paddlerProvider, child) {
        final paddlers = paddlerProvider.paddlers;
        final isRecording = paddlerProvider.isRecording;
        final duration = _sessionStartTime != null
            ? DateTime.now().difference(_sessionStartTime!)
            : const Duration();
        final currentAccel = paddlers.isNotEmpty
            ? paddlers.first.currentForce
            : 0.0;

        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildMetricsSection(duration, isRecording),
            const SizedBox(height: 16),
            // Live metric cards
            _buildCompactMetricsWrap([
              _buildCompactMetricCard(
                'Accel',
                '${currentAccel.toStringAsFixed(1)} m/s²',
                Icons.speed,
              ),
              _buildCompactMetricCard(
                'Stroke Rate',
                '${_liveSpm.toStringAsFixed(1)} spm',
                Icons.fitness_center,
              ),
              _buildCompactMetricCard(
                'Strokes',
                '$_liveTotalStrokes',
                Icons.countertops,
              ),
              _buildCompactMetricCard(
                'Pull Length',
                _liveMeanPullLength > 0
                    ? '${_liveMeanPullLength.toStringAsFixed(2)} m'
                    : '—',
                Icons.straighten,
                iconColor: Colors.purple.shade700,
              ),
              _buildCompactMetricCard(
                'Est. Force',
                '${_livePaddlingForce.toStringAsFixed(1)} N',
                Icons.bolt,
                iconColor: Colors.orange.shade700,
              ),
            ]),
            const SizedBox(height: 16),
            // Acceleration graph
            _buildSectionCard(
              title: 'Acceleration (m/s²)',
              child: ForceGraphWidget(
                key: _forceGraphKey,
                paddlers: paddlers,
                isRecording: isRecording,
              ),
            ),
            const SizedBox(height: 16),
            // 3D live paddle orientation
            _buildSectionCard(
              title: 'Paddle Orientation (Live)',
              child: SizedBox(
                height: 220,
                child: Cube(
                  interactive: false,
                  onSceneCreated: (scene) {
                    scene.camera.zoom = 8;
                    final obj = Object(fileName: 'assets/models/paddle.obj');
                    _paddleObj = obj;
                    scene.world.add(obj);
                    _ensureRenderTimer();
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }

  Widget _buildMetricsSection(Duration duration, bool isRecording) {
    return Consumer<PaddlerProvider>(
      builder: (context, provider, child) {
        return Row(
          children: [
            Expanded(
              child: _buildMetricCard(
                label: 'Duration',
                value: _formatDuration(duration),
                icon: Icons.timer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricCard(
                label: 'Paddlers',
                value: '${provider.paddlers.length}',
                icon: Icons.people,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: isRecording
                  ? ElevatedButton(
                      onPressed: _stopRecording,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.stop, size: 28),
                          SizedBox(height: 4),
                          Text('Stop', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    )
                  : ElevatedButton(
                      onPressed: _startConnecting,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.play_arrow, size: 28),
                          SizedBox(height: 4),
                          Text('Start', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMetricsSectionForPastSession(
    Duration duration,
    int paddlerCount,
  ) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            label: 'Duration',
            value: _formatDuration(duration),
            icon: Icons.timer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            label: 'Paddlers',
            value: '$paddlerCount',
            icon: Icons.people,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            label: 'Status',
            value: 'Past',
            icon: Icons.history,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.blue.shade600, size: 24),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactMetricsWrap(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        final width = constraints.maxWidth;
        final columns = width >= 900 ? 4 : (width >= 680 ? 3 : 2);
        final cardWidth = (width - (spacing * (columns - 1))) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: cards
              .map((card) => SizedBox(width: cardWidth, child: card))
              .toList(),
        );
      },
    );
  }

  Widget _buildCompactMetricCard(
    String label,
    String value,
    IconData icon, {
    Color? iconColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
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
          Icon(icon, size: 16, color: iconColor ?? Colors.blue.shade600),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  double _estimatePaddlingForce({
    required double accelMagnitude,
    required double strokeRateSpm,
    required int totalStrokes,
    required double timeSec,
    required double previousForce,
  }) {
    // Signature kept the same so the rest of the file does not need to change.
    const double baseline = 0.0;
    const double deadband = 0.25;
    const double maxDynamicAccel = 20.0;
    const double peakForceN = 180.0;
    const double gamma = 1.6;
    const double attackAlpha = 0.40;
    const double releaseAlpha = 0.18;

    final double dynamicAccel = (accelMagnitude - baseline).clamp(
      0.0,
      double.infinity,
    );
    final double effectiveAccel = (dynamicAccel - deadband).clamp(
      0.0,
      double.infinity,
    );

    if (effectiveAccel <= 1e-9) {
      final double decayed = previousForce * (1.0 - releaseAlpha);
      return decayed < 0.5 ? 0.0 : decayed;
    }

    final double norm = (effectiveAccel / maxDynamicAccel).clamp(0.0, 1.0);
    final double targetForce = peakForceN * pow(norm, gamma).toDouble();

    final double alpha = targetForce > previousForce
        ? attackAlpha
        : releaseAlpha;
    return previousForce + alpha * (targetForce - previousForce);
  }

  Widget _buildSectionCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ------------ Live subscriptions & 3D rendering ------------
  void _startLiveSubscriptions() {
    _liveBleSub?.cancel();
    final ble = Provider.of<BLEProvider>(context, listen: false);
    // For now, subscribe to the first connected device stream
    final paddlers = Provider.of<PaddlerProvider>(
      context,
      listen: false,
    ).paddlers;
    if (paddlers.isEmpty) return;
    final deviceId = paddlers.first.id;
    final stream = ble.getDataStream(deviceId);
    if (stream == null) return;

    _liveBleSub = stream.listen((evt) {
      // Establish t0 from BLE timestamps
      _t0Us ??= evt.timeUs;
      final tSec = ((_t0Us != null) ? (evt.timeUs - _t0Us!) : 0) / 1e6;

      if (evt.dataType == 0.0) {
        // Acceleration row -> stroke detector (ONLY when recording is active)
        if (_strokeCountingEnabled) {
          // Buffer raw components for pull-length detection.
          _pldAccT.add(tSec);
          _pldAccX.add(evt.accX);
          _pldAccY.add(evt.accY);
          _pldAccZ.add(evt.accZ);

          // Prefer gyro-based stroke signal if available, else fallback to |a|
          double? sig;
          if (_gyroMag.isNotEmpty) {
            // Trailing MA(15) of gyro magnitude (water-stroke smooth window)
            const w = 15;
            final cnt = _gyroMag.length < w ? _gyroMag.length : w;
            double s = 0.0;
            for (int i = 0; i < cnt; i++) {
              s += _gyroMag[_gyroMag.length - 1 - i];
            }
            final gSmooth = s / (cnt > 0 ? cnt : 1);

            // Rolling 3-second local min-max — window size derived from the
            // actual inter-arrival gap of the quaternion stream so it adapts
            // to the true sample rate (e.g. ~150 Hz → roll ≈ 450 frames).
            final dtLast = _qt.length >= 2
                ? (_qt.last - _qt[_qt.length - 2]).abs().clamp(1e-6, 1.0)
                : 0.02;
            final roll = (3.0 / dtLast).round().clamp(10, _gyroMag.length);
            final from = _gyroMag.length > roll ? _gyroMag.length - roll : 0;
            double mn = _gyroMag[from], mx = _gyroMag[from];
            for (int i = from + 1; i < _gyroMag.length; i++) {
              if (_gyroMag[i] < mn) mn = _gyroMag[i];
              if (_gyroMag[i] > mx) mx = _gyroMag[i];
            }
            final normSig = ((gSmooth - mn) / (mx - mn + 1e-9)).clamp(0.0, 1.0);

            // Noise gate: 30th-percentile of buffer × 2.0
            final bufSorted = List<double>.from(_gyroMag)..sort();
            final noiseFloor =
                bufSorted[((bufSorted.length - 1) * 0.30).round().clamp(
                  0,
                  bufSorted.length - 1,
                )];
            sig = gSmooth < noiseFloor * 2.0 ? 0.0 : normSig;
          }
          final mag = sqrt(
            evt.accX * evt.accX + evt.accY * evt.accY + evt.accZ * evt.accZ,
          );
          final upd = _strokeDetector.addSample(
            tSec: tSec,
            accelMag: sig ?? mag,
          );
          // Block-by-block pull-length update.
          _maybeLivePldUpdate(tSec);
          if (mounted) {
            setState(() {
              _liveSpm = upd.rateSpm;
              _liveTotalStrokes = upd.totalStrokes;
              _livePaddlingForce = _estimatePaddlingForce(
                accelMagnitude: mag,
                strokeRateSpm: _liveSpm,
                totalStrokes: _liveTotalStrokes,
                timeSec: tSec,
                previousForce: _livePaddlingForce,
              );
            });
          }
        }
      } else if (evt.dataType == 1.0) {
        // Quaternion row (q, i, j, k) -> (qw,qx,qy,qz)
        _qt.add(tSec);
        _qw.add(evt.qw);
        _qx.add(evt.qi);
        _qy.add(evt.qj);
        _qz.add(evt.qk);

        // Update live gyro-based stroke signal from successive quaternions
        if (_prevQt != null &&
            _prevQw != null &&
            _prevQx != null &&
            _prevQy != null &&
            _prevQz != null) {
          final dt = (tSec - _prevQt!).clamp(1e-6, 1.0);
          double w1 = _prevQw!, x1 = _prevQx!, y1 = _prevQy!, z1 = _prevQz!;
          double w2 = evt.qw, x2 = evt.qi, y2 = evt.qj, z2 = evt.qk;
          final n1 = sqrt(w1 * w1 + x1 * x1 + y1 * y1 + z1 * z1);
          final n2 = sqrt(w2 * w2 + x2 * x2 + y2 * y2 + z2 * z2);
          if (n1 > 1e-9) {
            w1 /= n1;
            x1 /= n1;
            y1 /= n1;
            z1 /= n1;
          } else {
            w1 = 1;
            x1 = y1 = z1 = 0;
          }
          if (n2 > 1e-9) {
            w2 /= n2;
            x2 /= n2;
            y2 /= n2;
            z2 /= n2;
          } else {
            w2 = 1;
            x2 = y2 = z2 = 0;
          }
          final dot = w1 * w2 + x1 * x2 + y1 * y2 + z1 * z2;
          if (dot < 0) {
            w2 = -w2;
            x2 = -x2;
            y2 = -y2;
            z2 = -z2;
          }
          final wc = w1, xc = -x1, yc = -y1, zc = -z1;
          final dw = wc * w2 - xc * x2 - yc * y2 - zc * z2;
          double dx = wc * x2 + xc * w2 + yc * z2 - zc * y2;
          double dy = wc * y2 - xc * z2 + yc * w2 + zc * x2;
          double dz = wc * z2 + xc * y2 - yc * x2 + zc * w2;
          final dnorm = sqrt(dw * dw + dx * dx + dy * dy + dz * dz);
          final ndw = dnorm > 1e-12 ? (dw / dnorm) : dw;
          dx = dnorm > 1e-12 ? dx / dnorm : dx;
          dy = dnorm > 1e-12 ? dy / dnorm : dy;
          dz = dnorm > 1e-12 ? dz / dnorm : dz;
          final wC = ndw.clamp(-1.0, 1.0);
          var angle = 2.0 * acos(wC);
          if (angle > pi) {
            angle = 2.0 * pi - angle;
            dx = -dx;
            dy = -dy;
            dz = -dz;
          }
          final s = sqrt((1.0 - wC * wC).clamp(1e-12, 1.0));
          if (s >= 1e-6 && dt > 1e-6 && angle > 1e-9) {
            final ax = dx / s, ay = dy / s, az = dz / s;
            final wx = ax * (angle / dt),
                wy = ay * (angle / dt),
                wz = az * (angle / dt);
            final gmag = sqrt(wx * wx + wy * wy + wz * wz);
            _gyroMag.add(gmag);
            if (_gyroMag.length > _gyroBufMax) _gyroMag.removeAt(0);
          } else if (_gyroMag.isNotEmpty) {
            _gyroMag.add(_gyroMag.last);
            if (_gyroMag.length > _gyroBufMax) _gyroMag.removeAt(0);
          }
        }
        _prevQt = tSec;
        _prevQw = evt.qw;
        _prevQx = evt.qi;
        _prevQy = evt.qj;
        _prevQz = evt.qk;
        // Buffer full quat timeline for PLD (no size cap).
        _pldQt.add(tSec);
        _pldQw.add(evt.qw);
        _pldQx.add(evt.qi);
        _pldQy.add(evt.qj);
        _pldQz.add(evt.qk);
        // Trim buffers
        if (_qt.length > _maxQuatSamples) {
          final drop = _qt.length - _maxQuatSamples;
          _qt.removeRange(0, drop);
          _qw.removeRange(0, drop);
          _qx.removeRange(0, drop);
          _qy.removeRange(0, drop);
          _qz.removeRange(0, drop);
        }
        // Rebuild live orientation for 3D paddle.
        if (_qt.length >= 2) {
          _livePaddle = PaddleOrientation(
            tSec: List<double>.from(_qt),
            qw: List<double>.from(_qw),
            qx: List<double>.from(_qx),
            qy: List<double>.from(_qy),
            qz: List<double>.from(_qz),
            fixedXDeg: 0.0,
            fixedYDeg: 45.0,
            fixedZDeg: 90.0,
            yawOnly: true,
          );
        }
      }
    });
  }

  void _ensureRenderTimer() {
    _renderTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_paddleObj == null || _livePaddle == null || _qt.isEmpty) return;
      final t = _qt.last;
      final e = _livePaddle!.eulerAt(t);
      _paddleObj!.rotation.setValues(e.x, e.y, e.z);
      _paddleObj!.updateTransform();
    });
  }

  void _ensureReplayTimer() {
    if (_replayPaddle == null || _replayObj == null) return;
    _replayTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_replayPaddle == null || _replayObj == null) return;
      _replayT += 1.0 / 30.0;
      if (_replayT > _replayTMax) _replayT = 0.0;
      final e = _replayPaddle!.eulerAt(_replayT);
      _replayObj!.rotation.setValues(e.x, e.y, e.z);
      _replayObj!.updateTransform();
    });
  }

  void _maybeLivePldUpdate(double tSec) {
    if (_pldAccT.length - _pldAccProcessedCount < _pldBlockSize) return;
    if (_pldQt.isEmpty) return;
    final rows = _pld.preprocess(
      tAcc: List<double>.from(_pldAccT),
      ax: List<double>.from(_pldAccX),
      ay: List<double>.from(_pldAccY),
      az: List<double>.from(_pldAccZ),
      tRot: List<double>.from(_pldQt),
      qw: List<double>.from(_pldQw),
      qx: List<double>.from(_pldQx),
      qy: List<double>.from(_pldQy),
      qz: List<double>.from(_pldQz),
    );
    if (rows.isEmpty) return;
    final peaks = _strokeDetector.allPeakTimes.where((t) => t <= tSec).toList();
    final result = _pld.process(rows, externalPeakTimes: peaks);
    _liveMeanPullLength = result.meanPullLength;
    _pldAccProcessedCount = _pldAccT.length;
  }

  // ------------ Replay 3D parsing & animation ------------
  Future<void> _initReplayQuaternionsIfAvailable() async {
    try {
      // Read raw CSV for this session and detect interleaved header
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/${widget.session.id}';
      final file = File(path);
      if (!await file.exists()) return;
      final content = await file.readAsString();
      final lines = content
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      if (lines.isEmpty) return;
      final header = lines.first.toLowerCase();
      if (!header.startsWith('time_us,time_dif_us,data_type')) return;

      _rt.clear();
      _rqw.clear();
      _rqx.clear();
      _rqy.clear();
      _rqz.clear();
      _histAccT.clear();
      _histAccX.clear();
      _histAccY.clear();
      _histAccZ.clear();

      // Find global t0 across ALL rows (accel + quat) so timelines align.
      double? t0Us;
      for (var i = 1; i < lines.length; i++) {
        final parts = lines[i].split(',');
        if (parts.length < 3) continue;
        final tUs = double.tryParse(parts[0]);
        if (tUs == null) continue;
        if (t0Us == null || tUs < t0Us) t0Us = tUs;
      }
      if (t0Us == null) return;

      // Single pass: parse both quat (type 1) and acc (type 0) rows.
      for (var i = 1; i < lines.length; i++) {
        final parts = lines[i].split(',');
        if (parts.length < 7) continue;
        final dataType = double.tryParse(parts[2]);
        final timeUs = double.tryParse(parts[0]);
        if (dataType == null || timeUs == null) continue;
        final tSec = (timeUs - t0Us) / 1e6;
        if (dataType == 1.0) {
          _rt.add(tSec);
          _rqw.add(double.tryParse(parts[3]) ?? 0.0);
          _rqx.add(double.tryParse(parts[4]) ?? 0.0);
          _rqy.add(double.tryParse(parts[5]) ?? 0.0);
          _rqz.add(double.tryParse(parts[6]) ?? 0.0);
        } else if (dataType == 0.0) {
          _histAccT.add(tSec);
          _histAccX.add(double.tryParse(parts[3]) ?? 0.0);
          _histAccY.add(double.tryParse(parts[4]) ?? 0.0);
          _histAccZ.add(double.tryParse(parts[5]) ?? 0.0);
        }
      }
      if (_rt.length >= 2) {
        _replayT = 0.0;
        _replayTMax = _rt.last;
        _replayPaddle = PaddleOrientation(
          tSec: _rt,
          qw: _rqw,
          qx: _rqx,
          qy: _rqy,
          qz: _rqz,
          fixedXDeg: 0.0,
          fixedYDeg: 45.0,
          fixedZDeg: 90.0,
          yawOnly: true,
        );
        // Build gyro-based stroke signal exactly as the test screen does.
        _buildReplayStrokeSignal();
        // Compute final session metrics (stroke count, SPM, mean pull length).
        _computeHistMetrics();
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Ignore CSV parse errors here
    }
  }

  /// Computes all historical session metrics:
  /// • Average acceleration, total strokes, mean SPM, mean pull length (final values)
  /// • Per-sample SPM / stroke-count timelines for live-replay metric updates
  /// • Accel timeline for the first paddler for fast replay lookups
  void _computeHistMetrics() {
    // Average acceleration + accel timeline from pre-loaded magnitude data.
    if (_historicalData != null && _historicalData!.isNotEmpty) {
      final allPts = _historicalData!.values.expand((pts) => pts).toList();
      if (allPts.isNotEmpty) {
        _histAvgAccel =
            allPts.map((p) => p.accel).reduce((a, b) => a + b) / allPts.length;
      }
      // Build fast-lookup timeline for the first paddler's accel.
      final firstKey = _historicalData!.keys.first;
      final firstPts = _historicalData![firstKey]!;
      _histAccelT = firstPts.map((p) => p.time).toList();
      _histAccelV = firstPts.map((p) => p.accel).toList();
    }

    // Stroke count + SPM: replay the gyro stroke signal through a fresh detector,
    // capturing the per-sample timeline for dynamic replay updates.
    if (_replayStrokeT.isNotEmpty && _replayStrokeSig.isNotEmpty) {
      final det = StrokeDetector(
        windowSec: 5.0,
        minPeakDistanceSec: 0.80,
        smoothingAlpha: 0.1,
        baselineAlpha: 0.05,
        thresholdMin: 0.55,
        thresholdK: 1.0,
        warmupSec: 0.5,
      );

      final timelineSpm = <double>[];
      final timelineCount = <int>[];
      StrokeUpdate lastUpd = const StrokeUpdate(0.0, 0, 0);

      for (var i = 0; i < _replayStrokeT.length; i++) {
        lastUpd = det.addSample(
          tSec: _replayStrokeT[i],
          accelMag: _replayStrokeSig[i],
        );
        timelineSpm.add(lastUpd.rateSpm);
        timelineCount.add(lastUpd.totalStrokes);
      }

      _histTimelineSpm = timelineSpm;
      _histTimelineCount = timelineCount;

      // Mean pull length via PLD — store per-stroke data for dynamic replay.
      if (_histAccT.isNotEmpty && _rt.isNotEmpty) {
        final rows = _pld.preprocess(
          tAcc: _histAccT,
          ax: _histAccX,
          ay: _histAccY,
          az: _histAccZ,
          tRot: _rt,
          qw: _rqw,
          qx: _rqx,
          qy: _rqy,
          qz: _rqz,
        );
        if (rows.isNotEmpty) {
          final result = _pld.process(
            rows,
            externalPeakTimes: det.allPeakTimes,
          );
          _histPeakTimes = List.from(result.peakTimes);
          _histPullLengths = List.from(result.pullLengths);
        }
      }
    }

    // Seed dynamic display values. Accel starts at session average so the card
    // is never blank; the others start at 0 and count up with the replay.
    _dynAccel = _histAvgAccel;
    _dynSpm = 0.0;
    _dynStrokes = 0;
    _dynPullLength = 0.0;
    _dynPseudoForce = 0.0;
  }

  /// Called every 100 ms by the historical graph replay timer.
  /// Updates all four metric cards to reflect the current replay position.
  void _onHistReplayTick(double timeSec) {
    if (!mounted) return;
    setState(() {
      // Stroke rate + count: binary search in the gyro-signal timeline.
      if (_replayStrokeT.isNotEmpty) {
        final idx = (_lowerBound(_replayStrokeT, timeSec) - 1).clamp(
          0,
          _replayStrokeT.length - 1,
        );
        _dynSpm = _histTimelineSpm.isNotEmpty ? _histTimelineSpm[idx] : 0.0;
        _dynStrokes = _histTimelineCount.isNotEmpty
            ? _histTimelineCount[idx]
            : 0;
      }
      // Current accel: binary search in the first paddler's accel timeline.
      if (_histAccelT.isNotEmpty) {
        final idx = (_lowerBound(_histAccelT, timeSec) - 1).clamp(
          0,
          _histAccelT.length - 1,
        );
        _dynAccel = _histAccelV[idx];
      }
      // Mean pull length: mean of all strokes whose peak is at or before now.
      if (_histPeakTimes.isNotEmpty) {
        final count = _lowerBound(_histPeakTimes, timeSec);
        if (count > 0 && count <= _histPullLengths.length) {
          double sum = 0;
          for (var i = 0; i < count; i++) {
            sum += _histPullLengths[i];
          }
          _dynPullLength = sum / count;
        } else {
          _dynPullLength = 0.0;
        }
      }
      _dynPseudoForce = _estimatePaddlingForce(
        accelMagnitude: _dynAccel,
        strokeRateSpm: _dynSpm,
        totalStrokes: _dynStrokes,
        timeSec: timeSec,
        previousForce: _dynPseudoForce,
      );
    });
  }

  /// Binary lower-bound (leftmost insertion point) on a sorted list.
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

  /// Mirrors StrokeTestScreen._buildStrokeSignal() exactly:
  /// normalize quats → enforce continuity → compute Δq gyro mag → MA(11) → 5–95% percentile norm.
  void _buildReplayStrokeSignal() {
    _replayStrokeT = [];
    _replayStrokeSig = [];
    final n = _rt.length;
    if (n < 2) return;

    // Working copies
    final qw = List<double>.from(_rqw);
    final qx = List<double>.from(_rqx);
    final qy = List<double>.from(_rqy);
    final qz = List<double>.from(_rqz);

    // Step 1: normalize + enforce quaternion continuity
    for (var i = 0; i < n; i++) {
      final norm = sqrt(
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

    // Step 2: compute angular velocity magnitude from Δq
    final dt = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      dt[i] = (_rt[i] - _rt[i - 1]).clamp(1e-3, 0.05);
    }
    final gyroMag = List<double>.filled(n, 0.0);
    for (var i = 1; i < n; i++) {
      double w1 = qw[i - 1], x1 = qx[i - 1], y1 = qy[i - 1], z1 = qz[i - 1];
      double w2 = qw[i], x2 = qx[i], y2 = qy[i], z2 = qz[i];
      // Δq = conj(q1) * q2
      final wc = w1, xc = -x1, yc = -y1, zc = -z1;
      final dw = wc * w2 - xc * x2 - yc * y2 - zc * z2;
      double dx = wc * x2 + xc * w2 + yc * z2 - zc * y2;
      double dy = wc * y2 - xc * z2 + yc * w2 + zc * x2;
      double dz = wc * z2 + xc * y2 - yc * x2 + zc * w2;
      final dnorm = sqrt(dw * dw + dx * dx + dy * dy + dz * dz);
      final ndw = dnorm > 1e-12 ? (dw / dnorm) : dw;
      dx = dnorm > 1e-12 ? dx / dnorm : dx;
      dy = dnorm > 1e-12 ? dy / dnorm : dy;
      dz = dnorm > 1e-12 ? dz / dnorm : dz;
      final wC = ndw.clamp(-1.0, 1.0);
      var angle = 2.0 * acos(wC);
      if (angle > pi) {
        angle = 2.0 * pi - angle;
        dx = -dx;
        dy = -dy;
        dz = -dz;
      }
      final s = sqrt((1.0 - wC * wC).clamp(1e-12, 1.0));
      if (s >= 1e-6 && dt[i] > 1e-6 && angle > 1e-9) {
        final ax = dx / s, ay = dy / s, az = dz / s;
        final wx = ax * (angle / dt[i]),
            wy = ay * (angle / dt[i]),
            wz = az * (angle / dt[i]);
        gyroMag[i] = sqrt(wx * wx + wy * wy + wz * wz);
      } else {
        gyroMag[i] = gyroMag[i - 1];
      }
    }
    if (n > 1) gyroMag[0] = gyroMag[1];

    // Centred moving-average helper
    List<double> ma(List<double> v, int w) {
      if (w <= 1) return List<double>.from(v);
      final out = List<double>.filled(v.length, 0.0);
      final h = w ~/ 2;
      for (var i = 0; i < v.length; i++) {
        double s = 0.0;
        int cnt = 0;
        for (var j = -h; j <= h; j++) {
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

    // Step 3: MA(15) — water-stroke smooth window
    final gSmooth = ma(gyroMag, 15);

    // Step 4: rolling 3-second local min-max normalisation
    final dts = List<double>.filled(n, 0.02);
    for (var i = 1; i < n; i++) {
      dts[i] = (_rt[i] - _rt[i - 1]).clamp(1e-3, 0.05);
    }
    final dtSorted = List<double>.from(dts.sublist(1))..sort();
    final medianDt = dtSorted.isNotEmpty
        ? dtSorted[dtSorted.length ~/ 2]
        : 0.02;
    final windowFrames = (3.0 / medianDt).round().clamp(10, n);
    final wHalf = windowFrames ~/ 2;

    final rollMin = List<double>.filled(n, 0.0);
    final rollMax = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      final from = (i - wHalf).clamp(0, n - 1);
      final to = (i + wHalf).clamp(0, n - 1);
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

    // Step 5: second MA(5) pass on the normalised signal
    final sig = ma(rawSig, 5);

    // Step 6: noise gate — zero where smoothed gyro < 2× 30th-percentile floor
    final gSmoothSorted = List<double>.from(gSmooth)..sort();
    final noiseFloor =
        gSmoothSorted[((gSmoothSorted.length - 1) * 0.30).round().clamp(
          0,
          gSmoothSorted.length - 1,
        )];
    for (var i = 0; i < n; i++) {
      if (gSmooth[i] < noiseFloor * 2.0) sig[i] = 0.0;
    }

    _replayStrokeT = List.from(_rt);
    _replayStrokeSig = sig;
  }
}
