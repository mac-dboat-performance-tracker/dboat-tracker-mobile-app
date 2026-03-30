import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/csv_logger.dart';

class BLEProvider extends ChangeNotifier {
  static final BLEProvider _instance = BLEProvider._internal();
  factory BLEProvider() => _instance;
  BLEProvider._internal();

  final Map<String, BluetoothDevice> _connectedDevices = {};

  /// Connection order for naming paddlers (first connected = Paddler 1, etc.)
  final List<String> _connectionOrder = [];
  final Map<String, StreamSubscription<List<int>>> _subscriptions = {};
  final Map<String, BluetoothCharacteristic> _characteristics = {};

  // Stream controllers for each device
  final Map<String, StreamController<SensorData>> _dataControllers = {};

  /// Per-device receive buffer for text CSV lines.
  /// Device sends rows as UTF-8 CSV:
  /// time_us,time_dif_us,data_type,value_1,value_2,value_3,value_4
  final Map<String, List<int>> _receiveBuffers = {};

  // Simple connection queue
  final List<String> _connectionQueue = [];
  bool _isConnecting = false;

  // Scan state management
  final Map<String, ScanResult> _scannedDevices = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  bool _isScanning = false;
  Timer? _scanRestartTimer;

  // Nordic UART Service (NUS) - matches microcontroller
  static const String serviceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  // NUS RX characteristic (notify) - receive data from device
  static const String characteristicUuid =
      '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';

  /// Only discover devices whose name starts with this (e.g. DB_IMU_BNO085).
  static const String deviceNamePrefix = 'DB_IMU';

  bool _isOurDevice(ScanResult result) {
    final name = result.advertisementData.localName.trim();
    if (name.isEmpty) return false;
    return name.toUpperCase().startsWith(deviceNamePrefix.toUpperCase());
  }

  // Getters
  Map<String, ScanResult> get scannedDevices =>
      Map.unmodifiable(_scannedDevices);
  bool get isScanning => _isScanning;

  // Stream to listen to sensor data
  Stream<SensorData>? getDataStream(String deviceId) {
    return _dataControllers[deviceId]?.stream;
  }

  // Start continuous scanning
  void startContinuousScan({
    Duration restartInterval = const Duration(seconds: 3),
  }) {
    if (_isScanning) return;

    _isScanning = true;
    notifyListeners();
    _performScan();

    _scanRestartTimer?.cancel();
    _scanRestartTimer = Timer.periodic(restartInterval, (timer) {
      if (_isScanning) {
        _performScan();
      } else {
        timer.cancel();
      }
    });
  }

  void _performScan() {
    _scanSubscription?.cancel();
    FlutterBluePlus.stopScan();

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      bool updated = false;
      for (var result in results) {
        if (!_isOurDevice(result)) continue;
        final deviceId = result.device.remoteId.toString();
        if (!_scannedDevices.containsKey(deviceId)) {
          _scannedDevices[deviceId] = result;
          updated = true;
        }
      }
      if (updated) notifyListeners();
    });

    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [],
    );
  }

  // Stop scanning
  Future<void> stopScan() async {
    _scanRestartTimer?.cancel();
    _scanRestartTimer = null;
    _scanSubscription?.cancel();
    _scanSubscription = null;
    await FlutterBluePlus.stopScan();
    if (_isScanning) {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// One-time scan; only devices whose name starts with [deviceNamePrefix] (DB_IMU) are emitted.
  Stream<List<ScanResult>> startScan() {
    FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 4),
      withServices: [],
    );
    return FlutterBluePlus.scanResults.map(
      (results) => results.where((r) => _isOurDevice(r)).toList(),
    );
  }

  // Connect and start monitoring a device (adds to queue)
  void startMonitoringDevice(String deviceId) {
    if (!_scannedDevices.containsKey(deviceId)) {
      print('Device $deviceId not found in scanned devices');
      return;
    }
    if (_connectedDevices.containsKey(deviceId) ||
        _connectionQueue.contains(deviceId)) {
      return; // Already connected or queued
    }

    _connectionQueue.add(deviceId);
    _processConnectionQueue();
  }

  // Process connection queue one at a time
  Future<void> _processConnectionQueue() async {
    if (_isConnecting || _connectionQueue.isEmpty) return;

    _isConnecting = true;
    final deviceId = _connectionQueue.removeAt(0);
    final device = _scannedDevices[deviceId]?.device;

    if (device == null) {
      _isConnecting = false;
      _processConnectionQueue();
      return;
    }

    try {
      await device.connect(timeout: const Duration(seconds: 15));
      final services = await device.discoverServices();
      final characteristic = _findCharacteristic(services);

      if (characteristic != null) {
        _characteristics[deviceId] = characteristic;
        await _setupNotifications(deviceId, characteristic);
        _connectedDevices[deviceId] = device;
        if (!_connectionOrder.contains(deviceId)) {
          _connectionOrder.add(deviceId);
        }
        notifyListeners();
      }
    } catch (e) {
      print('Error connecting to device $deviceId: $e');
    } finally {
      _isConnecting = false;
      _processConnectionQueue(); // Process next in queue
    }
  }

  // Find the appropriate characteristic
  BluetoothCharacteristic? _findCharacteristic(
    List<BluetoothService> services,
  ) {
    // Try to find by UUID first
    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.uuid.toString().toLowerCase() ==
                characteristicUuid.toLowerCase() ||
            service.uuid.toString().toLowerCase() ==
                serviceUuid.toLowerCase()) {
          return char;
        }
      }
    }

    // Fallback: use first available characteristic with notify
    if (services.isNotEmpty) {
      for (var service in services) {
        for (var char in service.characteristics) {
          if (char.properties.notify || char.properties.read) {
            return char;
          }
        }
      }
    }

    return null;
  }

  // Set up notifications for a characteristic
  Future<void> _setupNotifications(
    String deviceId,
    BluetoothCharacteristic characteristic,
  ) async {
    if (!characteristic.properties.notify) return;

    await characteristic.setNotifyValue(true);

    if (!_dataControllers.containsKey(deviceId)) {
      _dataControllers[deviceId] = StreamController<SensorData>.broadcast();
    }
    _receiveBuffers[deviceId] = [];

    final subscription = characteristic.onValueReceived.listen((value) {
      final buffer = _receiveBuffers[deviceId];
      if (buffer == null) return;
      buffer.addAll(value);

      // Reassemble stream into CSV lines. If no newline, detect complete line by comma count (6 commas => 7 fields).
      while (buffer.isNotEmpty) {
        final newlineIdx = buffer.indexOf(10);
        final lineEnd = newlineIdx >= 0 ? newlineIdx : buffer.length;
        final lineBytes = buffer.sublist(0, lineEnd);
        if (newlineIdx >= 0) {
          buffer.removeRange(0, newlineIdx + 1);
        } else {
          // No newline: only parse if we have a complete line (6 commas => 7 fields)
          if (lineBytes.where((b) => b == 0x2C).length < 6) break;
          buffer.removeRange(0, lineEnd);
        }
        if (lineBytes.isEmpty) continue;
        _handleCsvLine(deviceId, lineBytes);
      }
    });

    _subscriptions[deviceId] = subscription;
  }

  void _handleCsvLine(String deviceId, List<int> lineBytes) {
    String line;
    try {
      line = utf8.decode(lineBytes).replaceAll('\r', '').trim();
    } catch (_) {
      return;
    }
    if (line.isEmpty) return;
    final parts = line.split(',');
    if (parts.length < 7) return;

    final int? timeUs = int.tryParse(parts[0].trim());
    final int? timeDifUs = int.tryParse(parts[1].trim());
    final double? dataType = double.tryParse(parts[2].trim());
    final double v1 = double.tryParse(parts[3].trim()) ?? 0.0;
    final double v2 = double.tryParse(parts[4].trim()) ?? 0.0;
    final double v3 = double.tryParse(parts[5].trim()) ?? 0.0;
    final double v4 = double.tryParse(parts[6].trim()) ?? 0.0;

    if (timeUs == null || timeDifUs == null || dataType == null) return;

    // Forward both row types to UI stream for real-time consumption.
    final evt = dataType == 0.0
        ? SensorData(
            timeUs: timeUs,
            timeDifUs: timeDifUs,
            dataType: dataType,
            accX: v1,
            accY: v2,
            accZ: v3,
          )
        : SensorData(
            timeUs: timeUs,
            timeDifUs: timeDifUs,
            dataType: dataType,
            qw: v1,
            qi: v2,
            qj: v3,
            qk: v4,
          );
    _dataControllers[deviceId]?.add(evt);

    // Append raw row to CSV logger if recording.
    CSVLogger().appendInterleavedRow(
      timeUs: timeUs,
      timeDifUs: timeDifUs,
      dataType: dataType,
      value1: v1,
      value2: v2,
      value3: v3,
      value4: v4,
    );
  }

  // Disconnect from a device
  Future<void> disconnect(String deviceId) async {
    await _subscriptions[deviceId]?.cancel();
    _subscriptions.remove(deviceId);

    _dataControllers[deviceId]?.close();
    _dataControllers.remove(deviceId);

    _receiveBuffers.remove(deviceId);

    final device = _connectedDevices[deviceId];
    if (device != null) {
      await device.disconnect();
      _connectedDevices.remove(deviceId);
    }

    _connectionOrder.remove(deviceId);
    _characteristics.remove(deviceId);
    notifyListeners();
  }

  // Disconnect all devices
  Future<void> disconnectAll() async {
    for (var deviceId in _connectedDevices.keys.toList()) {
      await disconnect(deviceId);
    }
  }

  // Check if device is connected
  bool isConnected(String deviceId) {
    return _connectedDevices.containsKey(deviceId);
  }

  // Get all connected device IDs
  List<String> getConnectedDeviceIds() {
    return _connectedDevices.keys.toList();
  }

  /// Connected device IDs in order of connection (first = Paddler 1, etc.)
  List<String> getConnectedDeviceIdsInOrder() {
    return List.from(_connectionOrder);
  }

  /// Add a scan result so startMonitoringDevice can find the device. Only adds if device name matches.
  void addScannedDevice(ScanResult result) {
    if (!_isOurDevice(result)) return;
    final deviceId = result.device.remoteId.toString();
    if (!_scannedDevices.containsKey(deviceId)) {
      _scannedDevices[deviceId] = result;
      notifyListeners();
    }
  }

  // Clear scanned devices
  void clearScannedDevices() {
    _scannedDevices.clear();
    notifyListeners();
  }

  // Dispose method
  @override
  void dispose() {
    stopScan();
    disconnectAll();
    super.dispose();
  }
}

class SensorData {
  final int timeUs;
  final int timeDifUs;
  final double dataType; // 0.0 = accel (v1..v3), 1.0 = quaternion (v1..v4)
  // Acceleration (valid when dataType == 0.0)
  final double accX;
  final double accY;
  final double accZ;
  // Quaternion (valid when dataType == 1.0) in order q,i,j,k
  final double qw;
  final double qi;
  final double qj;
  final double qk;

  SensorData({
    required this.timeUs,
    required this.timeDifUs,
    required this.dataType,
    this.accX = 0.0,
    this.accY = 0.0,
    this.accZ = 0.0,
    this.qw = 0.0,
    this.qi = 0.0,
    this.qj = 0.0,
    this.qk = 0.0,
  });
}
