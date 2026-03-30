import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/session.dart';
import '../models/paddler.dart';
import '../widgets/force_graph_widget.dart';
import '../widgets/historical_force_graph_widget.dart';
import '../widgets/insights_section.dart';
import '../widgets/paddler_dashboard.dart';
import '../providers/paddler_provider.dart';
import '../providers/ble_provider.dart';
import '../services/csv_logger.dart';
import '../services/session_storage.dart';
import '../services/stroke_detector.dart';
import '../services/paddle_orientation.dart';
import 'package:flutter_cube/flutter_cube.dart';
import 'dart:math' show sqrt, acos, pi;
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
  List<Paddler> _replayPaddlers = []; // Paddlers updated during replay
  bool get _isPastSession => widget.session.id != 'session_new';

  // Live stroke metrics
  final StrokeDetector _strokeDetector = StrokeDetector(
    windowSec: 5.0,
    minPeakDistanceSec: 0.62,
    smoothingAlpha: 0.1,
    baselineAlpha: 0.05,
    thresholdMin: 0.57,
    thresholdK: 1.0,
    warmupSec: 0.5,
  );
  double _liveSpm = 0.0;
  int _liveTotalStrokes = 0;
  int? _t0Us;
  bool _strokeCountingEnabled = false;

  // Live quaternion buffer for 3D
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

  // Replay 3D buffers
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
  final int _gyroBufMax = 200;

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
          // Initialize replay paddlers with session paddlers
          _replayPaddlers = List.from(widget.session.paddlers);
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
    });

    // Reset stroke detection timeline to start at 0 for each recording.
    _strokeDetector.reset();
    _t0Us = null;
    _prevQt = null;
    _prevQw = _prevQx = _prevQy = _prevQz = null;
    _gyroMag.clear();

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
    // For past sessions, use session data; for new sessions, use provider
    if (_isPastSession) {
      if (_isLoadingHistoricalData) {
        return const Center(child: CircularProgressIndicator());
      }

      final duration = widget.session.duration;
      final paddlers = widget.session.paddlers;

      return ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Key Metrics Section
          _buildMetricsSectionForPastSession(duration, paddlers.length),
          const SizedBox(height: 16),
          // Replay Stroke Metrics (first paddler)
          if (_historicalData != null && _historicalData!.isNotEmpty)
            _buildSectionCard(
              title: 'Stroke (Replay)',
              child: _buildReplayStrokeMetrics(),
            ),
          if (_historicalData != null && _historicalData!.isNotEmpty)
            const SizedBox(height: 16),
          // Paddler Dashboard
          _buildSectionCard(
            title: 'Paddler Dashboard',
            child: PaddlerDashboard(
              paddlers: _replayPaddlers.isNotEmpty ? _replayPaddlers : paddlers,
              isRecording: false,
            ),
          ),
          const SizedBox(height: 16),
          // Force Graph
          _buildSectionCard(
            title: 'Acceleration (m/s²)',
            child: _historicalData != null
                ? HistoricalForceGraphWidget(
                    key: ValueKey('historical_${widget.session.id}'),
                    paddlers: paddlers,
                    historicalData: _historicalData!,
                    onReplayUpdate: (updatedPaddlers) {
                      // Update replay paddlers during replay
                      if (mounted) {
                        setState(() {
                          _replayPaddlers = updatedPaddlers;
                        });
                      }
                    },
                  )
                : const Center(child: Text('No historical data available')),
          ),
          const SizedBox(height: 16),
          // 3D Replay (if available)
          if (_replayPaddle != null)
            _buildSectionCard(
              title: '3D Replay',
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
          // Insights Section
          _buildSectionCard(
            title: 'ML Insights',
            child: InsightsSection(paddlers: paddlers),
          ),
          const SizedBox(height: 16),
        ],
      );
    }

    // For new/active sessions
    return Consumer<PaddlerProvider>(
      builder: (context, paddlerProvider, child) {
        final paddlers = paddlerProvider.paddlers;
        final isRecording = paddlerProvider.isRecording;
        final duration = _sessionStartTime != null
            ? DateTime.now().difference(_sessionStartTime!)
            : const Duration();

        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Key Metrics Section
            _buildMetricsSection(duration, isRecording),
            const SizedBox(height: 16),
            // Paddler Dashboard
            _buildSectionCard(
              title: 'Paddler Dashboard',
              child: PaddlerDashboard(
                paddlers: paddlers,
                isRecording: isRecording,
              ),
            ),
            const SizedBox(height: 16),
            // Live Stroke Metrics + 3D View
            _buildSectionCard(
              title: 'Stroke & 3D',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          label: 'SPM',
                          value: _liveSpm.toStringAsFixed(1),
                          icon: Icons.fitness_center,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricCard(
                          label: 'Strokes',
                          value: '$_liveTotalStrokes',
                          icon: Icons.countertops,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 220,
                    child: Cube(
                      interactive: false,
                      onSceneCreated: (scene) {
                        scene.camera.zoom = 8;
                        final obj = Object(
                          fileName: 'assets/models/paddle.obj',
                        );
                        _paddleObj = obj;
                        scene.world.add(obj);
                        _ensureRenderTimer();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Force Graph
            _buildSectionCard(
              title: 'Acceleration (m/s²)',
              child: ForceGraphWidget(
                key: _forceGraphKey,
                paddlers: paddlers,
                isRecording: isRecording,
              ),
            ),
            const SizedBox(height: 16),
            // Insights Section
            _buildSectionCard(
              title: 'ML Insights',
              child: InsightsSection(paddlers: paddlers),
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
          // Prefer gyro-based stroke signal if available, else fallback to |a|
          double? sig;
          if (_gyroMag.isNotEmpty) {
            // Smooth with small trailing average (~11)
            final w = 11;
            final cnt = _gyroMag.length < w ? _gyroMag.length : w;
            double s = 0.0;
            for (int i = 0; i < cnt; i++) {
              s += _gyroMag[_gyroMag.length - 1 - i];
            }
            final gSmooth = s / (cnt > 0 ? cnt : 1);
            final copy = List<double>.from(_gyroMag)..sort();
            double pick(double p) {
              if (copy.isEmpty) return 0.0;
              final idx = ((copy.length - 1) * p).round().clamp(
                0,
                copy.length - 1,
              );
              return copy[idx];
            }

            final low = pick(0.05);
            final high = pick(0.95);
            final denom = (high > low) ? (high - low) : 1e-6;
            sig = ((gSmooth - low) / denom).clamp(0.0, 1.0);
          }
          final mag = sqrt(
            evt.accX * evt.accX + evt.accY * evt.accY + evt.accZ * evt.accZ,
          );
          final upd = _strokeDetector.addSample(
            tSec: tSec,
            accelMag: sig ?? mag,
          );
          if (mounted) {
            setState(() {
              _liveSpm = upd.rateSpm;
              _liveTotalStrokes = upd.totalStrokes;
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
          final dt = (tSec - _prevQt!).clamp(1e-3, 0.05);
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
        // Trim buffers
        if (_qt.length > _maxQuatSamples) {
          final drop = _qt.length - _maxQuatSamples;
          _qt.removeRange(0, drop);
          _qw.removeRange(0, drop);
          _qx.removeRange(0, drop);
          _qy.removeRange(0, drop);
          _qz.removeRange(0, drop);
        }
        // Rebuild orientation with current buffers
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
      // Drive using latest timestamp in buffer
      final t = _qt.isNotEmpty ? _qt.last : 0.0;
      final e = _livePaddle!.eulerAt(t);
      _paddleObj!.rotation.setValues(e.x, e.y, e.z);
      _paddleObj!.updateTransform();
    });
  }

  Widget _buildReplayStrokeMetrics() {
    final firstKey = _historicalData!.keys.first;
    final series = _historicalData![firstKey]!;
    if (series.isEmpty) {
      return const Text('No data');
    }

    final det = StrokeDetector(
      windowSec: 5.0,
      minPeakDistanceSec: 0.62,
      smoothingAlpha: 0.1,
      baselineAlpha: 0.05,
      thresholdMin: 0.57,
      thresholdK: 1.0,
      warmupSec: 0.5,
    );

    int total = 0;
    double lastSpm = 0.0;

    final hasGyroSignal =
        _replayStrokeT.isNotEmpty && _replayStrokeSig.isNotEmpty;

    // Compute metrics only up to the current replay time so replay starts at zero.
    final tLimit = _replayT;
    for (final p in series) {
      if (p.time > tLimit) break;
      double sig;
      if (hasGyroSignal) {
        // Nearest-neighbour lookup on gyro stroke signal — identical to test screen replay
        var j = _lowerBound(_replayStrokeT, p.time);
        if (j > 0 && j < _replayStrokeT.length) {
          final prev = (p.time - _replayStrokeT[j - 1]).abs();
          final next = (_replayStrokeT[j] - p.time).abs();
          if (prev <= next) j = j - 1;
        } else if (j >= _replayStrokeT.length) {
          j = _replayStrokeT.length - 1;
        }
        sig = _replayStrokeSig[j];
      } else {
        sig = p.accel; // fallback for old-format sessions
      }
      final upd = det.addSample(tSec: p.time, accelMag: sig);
      total = upd.totalStrokes;
      lastSpm = upd.rateSpm;
    }
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            label: 'SPM (last window)',
            value: lastSpm.toStringAsFixed(1),
            icon: Icons.fitness_center,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            label: 'Total Strokes',
            value: '$total',
            icon: Icons.countertops,
          ),
        ),
      ],
    );
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

      for (var i = 1; i < lines.length; i++) {
        final parts = lines[i].split(',');
        if (parts.length < 7) continue;
        final dataType = double.tryParse(parts[2]);
        if (dataType == null || dataType != 1.0) continue;
        final timeUs = double.tryParse(parts[0]);
        if (timeUs == null) continue;
        final tSec = (timeUs - t0Us) / 1e6;
        final qw = double.tryParse(parts[3]) ?? 0.0;
        final qi = double.tryParse(parts[4]) ?? 0.0;
        final qj = double.tryParse(parts[5]) ?? 0.0;
        final qk = double.tryParse(parts[6]) ?? 0.0;
        _rt.add(tSec);
        _rqw.add(qw);
        _rqx.add(qi);
        _rqy.add(qj);
        _rqz.add(qk);
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
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Ignore CSV parse errors here
    }
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

    // Step 3: moving average window 11 (identical to test screen)
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

    final gSmooth = ma(gyroMag, 11);

    // Step 4: global 5–95% percentile normalization (identical to test screen)
    final sorted = List<double>.from(gSmooth)..sort();
    double pickP(double p) {
      if (sorted.isEmpty) return 0.0;
      final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
      return sorted[idx];
    }

    final low = pickP(0.05);
    final high = pickP(0.95);
    final denom = (high > low) ? (high - low) : 1e-6;

    _replayStrokeT = List.from(_rt);
    _replayStrokeSig = List<double>.generate(n, (i) {
      final v = (gSmooth[i] - low) / denom;
      return v < 0 ? 0.0 : (v > 1.0 ? 1.0 : v);
    });
  }

  /// Binary lower-bound helper used for nearest-neighbour lookup on sorted time lists.
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

  void _ensureReplayTimer() {
    if (_replayPaddle == null || _replayObj == null) return;
    _replayTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (_replayPaddle == null || _replayObj == null) return;
      // Advance time; simple looping playback
      _replayT += 1.0 / 30.0;
      if (_replayT > _replayTMax) _replayT = 0.0;
      final e = _replayPaddle!.eulerAt(_replayT);
      _replayObj!.rotation.setValues(e.x, e.y, e.z);
      _replayObj!.updateTransform();
      if (mounted) {
        setState(() {
          // Update replay stroke metrics UI to match the replay timeline.
        });
      }
    });
  }
}
