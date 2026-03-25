import 'dart:async';
import 'dart:math' show sqrt;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/ble_provider.dart';
import '../services/paddler_storage.dart';

class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  final Map<String, double> _deviceAccelerationMagnitude = {};
  final Map<String, StreamSubscription> _dataSubscriptions = {};
  String? _activeDeviceId;

  BLEProvider get _bleProvider =>
      Provider.of<BLEProvider>(context, listen: false);

  @override
  void initState() {
    super.initState();
    _bleProvider.addListener(_onBLEStateChanged);
    _startScanning();
    _startMonitoringExistingDevices();
  }

  void _onBLEStateChanged() {
    if (!mounted) return;
    final connectedIds = _bleProvider.getConnectedDeviceIds();
    // Clean up state for devices that are no longer connected (e.g. disconnected elsewhere or dropped)
    for (var deviceId in _dataSubscriptions.keys.toList()) {
      if (!connectedIds.contains(deviceId)) {
        _dataSubscriptions[deviceId]?.cancel();
        _dataSubscriptions.remove(deviceId);
        _deviceAccelerationMagnitude.remove(deviceId);
        if (_activeDeviceId == deviceId) _activeDeviceId = null;
      }
    }
    setState(() {});
    // Start monitoring new devices
    for (var deviceId in _bleProvider.scannedDevices.keys) {
      _startMonitoringDevice(deviceId);
    }
  }

  void _startMonitoringExistingDevices() {
    for (var deviceId in _bleProvider.scannedDevices.keys) {
      _startMonitoringDevice(deviceId);
    }
  }

  void _startScanning() {
    _bleProvider.startContinuousScan();
  }

  Widget _buildStatusChip({required bool isConnected, required bool hasData}) {
    if (isConnected && hasData) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.shade100,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.shade700, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 4),
            Text(
              'Connected',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.green.shade800,
              ),
            ),
          ],
        ),
      );
    }
    if (isConnected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.orange.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          'Connecting...',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Colors.orange.shade800,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'Not connected',
        style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
      ),
    );
  }

  void _startMonitoringDevice(String deviceId) {
    // Skip if already monitoring
    if (_dataSubscriptions.containsKey(deviceId)) return;

    // Tell BLEProvider to connect and monitor
    _bleProvider.startMonitoringDevice(deviceId);

    // Subscribe to data stream (will be available once connected)
    _subscribeToDeviceData(deviceId);
  }

  Future<void> _disconnectDevice(String deviceId) async {
    await _dataSubscriptions[deviceId]?.cancel();
    _dataSubscriptions.remove(deviceId);
    _deviceAccelerationMagnitude.remove(deviceId);
    if (_activeDeviceId == deviceId) _activeDeviceId = null;
    await _bleProvider.disconnect(deviceId);
    if (mounted) setState(() {});
  }

  void _subscribeToDeviceData(String deviceId) {
    // Skip if already subscribed
    if (_dataSubscriptions.containsKey(deviceId)) return;

    // Try to get stream, retry if not ready yet
    final dataStream = _bleProvider.getDataStream(deviceId);
    if (dataStream != null) {
      final subscription = dataStream.listen(
        (sensorData) {
          if (mounted) {
            final ax = sensorData.accX;
            final ay = sensorData.accY;
            final az = sensorData.accZ;
            final magnitude = sqrt(ax * ax + ay * ay + az * az);
            setState(() {
              _deviceAccelerationMagnitude[deviceId] = magnitude;

              // Check for strong movement (acceleration magnitude > 15 m/s²)
              if (magnitude > 15 && _activeDeviceId == null) {
                _activeDeviceId = deviceId;
                _showCalibrationDialog(deviceId);
              }
            });
          }
        },
        onError: (error) {
          print('Error in data stream for $deviceId: $error');
          if (mounted) {
            _dataSubscriptions.remove(deviceId);
            _deviceAccelerationMagnitude.remove(deviceId);
            if (_activeDeviceId == deviceId) _activeDeviceId = null;
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted && _bleProvider.isConnected(deviceId)) {
                _subscribeToDeviceData(deviceId);
              }
            });
          }
        },
        onDone: () {
          if (mounted) {
            _dataSubscriptions.remove(deviceId);
            _deviceAccelerationMagnitude.remove(deviceId);
            if (_activeDeviceId == deviceId) _activeDeviceId = null;
            setState(() {});
          }
        },
      );
      _dataSubscriptions[deviceId] = subscription;
    } else {
      // Stream not ready yet, retry after connection
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted &&
            !_dataSubscriptions.containsKey(deviceId) &&
            _bleProvider.isConnected(deviceId)) {
          _subscribeToDeviceData(deviceId);
        }
      });
    }
  }

  void _showCalibrationDialog(String deviceId) {
    final TextEditingController nameController = TextEditingController();
    final magnitude = _deviceAccelerationMagnitude[deviceId] ?? 0.0;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Active Sensor Detected!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Strong movement detected: ${magnitude.toStringAsFixed(1)} m/s²',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Enter Paddler Name',
                hintText: 'e.g., Paddler 1',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _activeDeviceId = null;
              });
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                _savePaddler(deviceId, nameController.text.trim());
                Navigator.pop(context);
                setState(() {
                  _activeDeviceId = null;
                });
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _savePaddler(String deviceId, String name) async {
    try {
      await PaddlerStorage.savePaddlerName(deviceId, name);
      await PaddlerStorage.setCalibrated(deviceId, true);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Paddler "$name" saved successfully'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving paddler: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _bleProvider.removeListener(_onBLEStateChanged);
    for (var subscription in _dataSubscriptions.values) {
      subscription.cancel();
    }
    _bleProvider.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calibrate Sensors'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: Consumer<BLEProvider>(
        builder: (context, bleProvider, child) {
          return Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Colors.blue.shade700,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Calibration Instructions',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '1. Make sure sensors are powered on\n'
                          '2. Devices will be automatically connected when found\n'
                          '3. Apply strong movement (e.g. sharp tap or shake) to the sensor you want to calibrate\n'
                          '4. The app will detect the active sensor automatically\n'
                          '5. Enter a name for the paddler\n'
                          '6. Tap "Proceed" when done calibrating',
                          style: TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Scanned Devices (${bleProvider.scannedDevices.length})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (bleProvider.isScanning)
                      Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Scanning...',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: bleProvider.scannedDevices.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.bluetooth_searching,
                                size: 64,
                                color: Colors.grey.shade400,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                bleProvider.isScanning
                                    ? 'Scanning for devices...'
                                    : 'No devices found',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: bleProvider.scannedDevices.length,
                          itemBuilder: (context, index) {
                            final entry = bleProvider.scannedDevices.entries
                                .elementAt(index);
                            final deviceId = entry.key;
                            final scanResult = entry.value;
                            final magnitude =
                                _deviceAccelerationMagnitude[deviceId] ?? 0.0;
                            final isActive = _activeDeviceId == deviceId;

                            final isConnected = _bleProvider.isConnected(
                              deviceId,
                            );
                            final hasData = _dataSubscriptions.containsKey(
                              deviceId,
                            );
                            final deviceName =
                                scanResult.advertisementData.localName
                                    .trim()
                                    .isNotEmpty
                                ? scanResult.advertisementData.localName.trim()
                                : (scanResult.device.platformName.isNotEmpty
                                      ? scanResult.device.platformName
                                      : 'Unknown Device');

                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              color: isActive
                                  ? Colors.green.shade50
                                  : isConnected
                                  ? Colors.blue.shade50
                                  : null,
                              child: ListTile(
                                leading: Stack(
                                  children: [
                                    Icon(
                                      isConnected
                                          ? Icons.bluetooth_connected
                                          : Icons.bluetooth,
                                      color: isActive
                                          ? Colors.green
                                          : isConnected
                                          ? Colors.blue
                                          : Colors.grey,
                                      size: 28,
                                    ),
                                    if (isConnected && hasData)
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        child: Container(
                                          width: 10,
                                          height: 10,
                                          decoration: BoxDecoration(
                                            color: Colors.green,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        deviceName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    _buildStatusChip(
                                      isConnected: isConnected,
                                      hasData: hasData,
                                    ),
                                    if (isConnected)
                                      IconButton(
                                        icon: const Icon(Icons.link_off),
                                        onPressed: () =>
                                            _disconnectDevice(deviceId),
                                        tooltip: 'Disconnect',
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                      ),
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      deviceId,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      isConnected && hasData
                                          ? 'Connected • Receiving sensor data (${magnitude.toStringAsFixed(1)} m/s²)'
                                          : isConnected
                                          ? 'Connected • Waiting for data...'
                                          : 'Tap to connect',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isConnected && hasData
                                            ? Colors.green.shade700
                                            : isConnected
                                            ? Colors.orange.shade700
                                            : Colors.grey.shade600,
                                        fontWeight: isConnected && hasData
                                            ? FontWeight.w500
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '${magnitude.toStringAsFixed(1)} m/s²',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: magnitude > 15
                                            ? Colors.red
                                            : Colors.grey,
                                      ),
                                    ),
                                    if (isActive)
                                      Container(
                                        margin: const EdgeInsets.only(top: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: const Text(
                                          'ACTIVE',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                onTap: () {
                                  if (!isConnected) {
                                    _startMonitoringDevice(deviceId);
                                  }
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
