import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/paddler.dart';

/// Logs paddler acceleration to CSV at a fixed sample rate during recording.
class CSVLogger {
  static final CSVLogger _instance = CSVLogger._internal();
  factory CSVLogger() => _instance;
  CSVLogger._internal();

  /// Sample rate in Hz. 10 Hz is a good balance for force/IMU (not too big, enough resolution).
  static const int kSampleRateHz = 10;
  static const int _intervalMs = 1000 ~/ kSampleRateHz;

  File? _csvFile;
  bool _isLogging = false;
  Timer? _loggingTimer;
  bool _isWriting = false;
  final List<String> _writeQueue = [];
  DateTime? _sessionStartTime;
  List<Paddler> Function()? _getPaddlers;

  Future<void> startLogging(
    List<Paddler> paddlers, {
    List<Paddler> Function()? getPaddlers,
  }) async {
    if (_isLogging) return;

    if (_csvFile != null && await _csvFile!.exists()) {
      try {
        await _csvFile!.delete();
      } catch (e) {
        print('Error deleting old CSV file: $e');
      }
    }

    final directory = await getApplicationDocumentsDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    _csvFile = File('${directory.path}/session_$timestamp.csv');
    _sessionStartTime = DateTime.now();
    _getPaddlers = getPaddlers;

    const header = 'timestamp_s,paddler_id,paddler_name,force_n,x,y\n';
    await _csvFile!.writeAsString(header);

    _isLogging = true;
    final startTime = DateTime.now();

    _loggingTimer = Timer.periodic(const Duration(milliseconds: _intervalMs), (
      timer,
    ) {
      if (!_isLogging) {
        timer.cancel();
        return;
      }
      final elapsedSec =
          DateTime.now().difference(startTime).inMilliseconds / 1000.0;
      final currentPaddlers = _getPaddlers != null ? _getPaddlers!() : paddlers;
      _logDataPoint(currentPaddlers, elapsedSec);
    });
  }

  void _logDataPoint(List<Paddler> paddlers, double timestampSec) {
    if (_csvFile == null) return;

    final buffer = StringBuffer();
    for (var paddler in paddlers) {
      buffer.writeln(
        '$timestampSec,${paddler.id},${paddler.name},${paddler.accX},${paddler.accY},${paddler.accZ}',
      );
    }
    _writeQueue.add(buffer.toString());
    _processWriteQueue();
  }

  Future<void> _processWriteQueue() async {
    if (_isWriting || _writeQueue.isEmpty || _csvFile == null) return;

    _isWriting = true;
    while (_writeQueue.isNotEmpty && _csvFile != null) {
      final data = _writeQueue.removeAt(0);
      try {
        await _csvFile!.writeAsString(data, mode: FileMode.append);
      } catch (e) {
        print('Error writing to CSV: $e');
      }
    }
    _isWriting = false;
  }

  /// Drains the write queue (e.g. after stopping the timer).
  Future<void> _drainWriteQueue() async {
    for (var i = 0; i < 20; i++) {
      await _processWriteQueue();
      if (_writeQueue.isEmpty) break;
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<String?> stopLogging({String? sessionName}) async {
    if (!_isLogging && _csvFile == null) return null;

    _isLogging = false;
    _loggingTimer?.cancel();
    _loggingTimer = null;

    await _drainWriteQueue();

    // Rename file with session name if provided
    if (sessionName != null && _csvFile != null && await _csvFile!.exists()) {
      final directory = await getApplicationDocumentsDirectory();
      // Sanitize filename (remove invalid characters)
      final sanitizedName = sessionName
          .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
          .replaceAll(' ', '_');
      final newPath = '${directory.path}/$sanitizedName.csv';

      // If file with same name exists, delete it first
      final existingFile = File(newPath);
      if (await existingFile.exists()) {
        await existingFile.delete();
      }

      final newFile = await _csvFile!.rename(newPath);
      _csvFile = newFile;
      _getPaddlers = null; // Clear reference
      return newFile.path;
    }

    // If no session name, just clear the file reference (don't save)
    if (sessionName == null && _csvFile != null) {
      try {
        if (await _csvFile!.exists()) {
          await _csvFile!.delete();
        }
      } catch (e) {
        print('Error deleting unsaved CSV file: $e');
      }
      _csvFile = null;
      _getPaddlers = null;
    }

    return _csvFile?.path;
  }

  // Get the log file path
  String? getLogFilePath() {
    return _csvFile?.path;
  }

  // Get session start time
  DateTime? getSessionStartTime() {
    return _sessionStartTime;
  }
}
