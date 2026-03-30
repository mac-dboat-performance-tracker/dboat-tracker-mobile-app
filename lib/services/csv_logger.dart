import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/paddler.dart';

/// Logs paddler acceleration to CSV at a fixed sample rate during recording.
class CSVLogger {
  static final CSVLogger _instance = CSVLogger._internal();
  factory CSVLogger() => _instance;
  CSVLogger._internal();

  File? _csvFile;
  bool _isLogging = false;
  bool _isWriting = false;
  final List<String> _writeQueue = [];
  DateTime? _sessionStartTime;

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

    // New interleaved IMU schema header (matches live BLE rows):
    // time_us,time_dif_us,data_type,value_1,value_2,value_3,value_4
    const header =
        'time_us,time_dif_us,data_type,value_1,value_2,value_3,value_4\n';
    await _csvFile!.writeAsString(header);

    _isLogging = true;
  }

  /// Append a single interleaved IMU row (already in target schema).
  /// Only writes when logging has started.
  void appendInterleavedRow({
    required int timeUs,
    required int timeDifUs,
    required double dataType,
    required double value1,
    required double value2,
    required double value3,
    required double value4,
  }) {
    if (!_isLogging || _csvFile == null) return;
    final line =
        '$timeUs,$timeDifUs,${dataType.toStringAsFixed(1)},$value1,$value2,$value3,$value4\n';
    _writeQueue.add(line);
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
