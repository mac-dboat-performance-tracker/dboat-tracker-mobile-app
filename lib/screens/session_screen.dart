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
import 'dart:math' show sqrt;

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
  final StrokeDetector _strokeDetector = StrokeDetector();
  double _liveSpm = 0.0;
  int _liveTotalStrokes = 0;
  int? _t0Us;

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
    });

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
        // Acceleration row -> stroke detector
        final mag = sqrt(
          evt.accX * evt.accX + evt.accY * evt.accY + evt.accZ * evt.accZ,
        );
        final upd = _strokeDetector.addSample(tSec: tSec, accelMag: mag);
        if (mounted) {
          setState(() {
            _liveSpm = upd.rateSpm;
            _liveTotalStrokes = upd.totalStrokes;
          });
        }
      } else if (evt.dataType == 1.0) {
        // Quaternion row (q, i, j, k) -> (qw,qx,qy,qz)
        _qt.add(tSec);
        _qw.add(evt.qw);
        _qx.add(evt.qi);
        _qy.add(evt.qj);
        _qz.add(evt.qk);
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
}
