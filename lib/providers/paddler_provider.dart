import 'dart:async';
import 'dart:math' show sqrt;
import 'package:flutter/material.dart';
import '../models/paddler.dart';
import 'ble_provider.dart';

class PaddlerProvider extends ChangeNotifier {
  final BLEProvider _bleProvider = BLEProvider();
  final List<Paddler> _paddlers = [];
  final Map<String, StreamSubscription> _subscriptions = {};
  bool _isRecording = false;

  static const List<Color> _paddlerColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.amber,
  ];

  List<Paddler> get paddlers => List.unmodifiable(_paddlers);

  bool get isRecording => _isRecording;

  PaddlerProvider() {
    _bleProvider.addListener(_onBLEStateChanged);
  }

  void _onBLEStateChanged() {
    syncPaddlersFromConnectedDevices();
  }

  void _subscribeToConnectedDevices() {
    for (var paddler in _paddlers) {
      // Skip if already subscribed
      if (_subscriptions.containsKey(paddler.id)) continue;

      // Check if device is connected and subscribe
      if (_bleProvider.isConnected(paddler.id)) {
        final dataStream = _bleProvider.getDataStream(paddler.id);
        if (dataStream != null) {
          final subscription = dataStream.listen((sensorData) {
            // Only update paddler acceleration on acceleration rows (data_type == 0.0)
            if (sensorData.dataType == 0.0) {
              _updatePaddlerData(
                paddler.id,
                sensorData.accX,
                sensorData.accY,
                sensorData.accZ,
              );
            }
          });
          _subscriptions[paddler.id] = subscription;
        }
      }
    }
    notifyListeners();
  }

  /// Paddlers = currently connected BLE devices, named Paddler 1, 2, 3... by connection order.
  /// During recording we do not add new devices — only remove disconnected ones.
  /// Reuses existing Paddler instances when still connected so graph/session state is preserved.
  void syncPaddlersFromConnectedDevices() {
    var connectedIds = _bleProvider.getConnectedDeviceIdsInOrder();
    if (connectedIds.isEmpty) {
      connectedIds = _bleProvider.getConnectedDeviceIds();
    }

    if (_isRecording && _paddlers.isNotEmpty) {
      connectedIds = connectedIds
          .where((id) => _paddlers.any((p) => p.id == id))
          .toList();
    }

    for (var deviceId in _subscriptions.keys.toList()) {
      if (!connectedIds.contains(deviceId)) {
        _subscriptions[deviceId]?.cancel();
        _subscriptions.remove(deviceId);
      }
    }

    final newPaddlers = <Paddler>[];
    for (var i = 0; i < connectedIds.length; i++) {
      final deviceId = connectedIds[i];
      final existing = _paddlers.where((p) => p.id == deviceId).firstOrNull;
      final name = 'Paddler ${i + 1}';
      final color = _paddlerColors[i % _paddlerColors.length];
      if (existing != null) {
        newPaddlers.add(existing.copyWith(name: name, color: color));
      } else {
        newPaddlers.add(
          Paddler(
            id: deviceId,
            name: name,
            color: color,
            forceData: [],
            insights: [],
            position3D: PaddlePosition(x: 0, y: 0, z: 0),
            currentForce: 0.0,
            position: [0, 0],
          ),
        );
      }
    }
    _paddlers
      ..clear()
      ..addAll(newPaddlers);

    _subscribeToConnectedDevices();
    notifyListeners();
  }

  /// Scan only; found devices appear in BLEProvider.scannedDevices. Does not connect.
  Future<void> scanForDevices() async {
    final scanStream = _bleProvider.startScan();
    final scanSubscription = scanStream.listen((results) {
      for (var result in results) {
        _bleProvider.addScannedDevice(result);
      }
    });
    await Future.delayed(const Duration(seconds: 5));
    scanSubscription.cancel();
    await _bleProvider.stopScan();
    notifyListeners();
  }

  /// Connect only to the selected device IDs (must be in BLEProvider.scannedDevices).
  Future<void> connectToSelectedDevices(List<String> deviceIds) async {
    if (deviceIds.isEmpty) {
      notifyListeners();
      return;
    }
    for (var deviceId in deviceIds) {
      if (!_bleProvider.isConnected(deviceId)) {
        _bleProvider.startMonitoringDevice(deviceId);
      }
    }
    int maxWait = (deviceIds.length * 4).clamp(5, 25);
    for (int i = 0; i < maxWait; i++) {
      await Future.delayed(const Duration(seconds: 1));
      bool allDone = true;
      for (var deviceId in deviceIds) {
        if (!_bleProvider.isConnected(deviceId)) {
          allDone = false;
          break;
        }
      }
      if (allDone) break;
    }
    syncPaddlersFromConnectedDevices();
    notifyListeners();
  }

  // Update paddler data from acceleration (m/s²); currentForce = magnitude for graph
  void _updatePaddlerData(String id, double accX, double accY, double accZ) {
    final index = _paddlers.indexWhere((p) => p.id == id);
    if (index != -1) {
      final magnitude = sqrt(accX * accX + accY * accY + accZ * accZ);
      final paddler = _paddlers[index];
      _paddlers[index] = paddler.copyWith(
        accX: accX,
        accY: accY,
        accZ: accZ,
        currentForce: magnitude,
      );
      notifyListeners();
    }
  }

  // Start recording — only BLE data is used; no dummy data
  void startRecording() {
    _isRecording = true;
    notifyListeners();
  }

  // Stop recording
  void stopRecording() {
    _isRecording = false;

    // Reset paddler data to initial state
    for (int i = 0; i < _paddlers.length; i++) {
      _paddlers[i] = _paddlers[i].copyWith(
        currentForce: 0.0,
        position: [0, 0],
        accX: 0.0,
        accY: 0.0,
        accZ: 0.0,
      );
    }

    notifyListeners();
  }

  // Disconnect all devices
  Future<void> disconnectAll() async {
    for (var subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _bleProvider.disconnectAll();
  }

  @override
  void dispose() {
    _bleProvider.removeListener(_onBLEStateChanged);
    disconnectAll();
    super.dispose();
  }
}
