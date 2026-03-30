import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/session.dart';
import '../models/paddler.dart';

class SessionStorage {
  // Get all saved sessions from CSV files
  static Future<List<Session>> getAllSessions() async {
    final List<Session> sessions = [];

    try {
      final directory = await getApplicationDocumentsDirectory();
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.csv'))
          .toList();

      // Sort by modification date (newest first)
      files.sort(
        (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
      );

      for (var file in files) {
        try {
          final session = await _parseSessionFromFile(file);
          if (session != null) {
            sessions.add(session);
          }
        } catch (e) {
          print('Error parsing session file ${file.path}: $e');
          // Continue with next file
        }
      }
    } catch (e) {
      print('Error loading sessions: $e');
    }

    return sessions;
  }

  // Parse a CSV file to extract session information
  static Future<Session?> _parseSessionFromFile(File file) async {
    try {
      final content = await file.readAsString();
      final lines = content
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();

      if (lines.length < 2) {
        // Need at least header + one data line
        return null;
      }

      // Extract filename (without .csv extension) as session name
      final fileName = file.path.split('/').last.replaceAll('.csv', '');
      final sessionName = fileName.replaceAll('_', ' ');

      // Parse CSV to get metadata
      final dataLines = lines.sublist(1);

      if (dataLines.isEmpty) {
        return null;
      }

      final header = lines[0].toLowerCase();
      final isInterleaved = header.startsWith('time_us,time_dif_us,data_type');

      // Get unique paddler IDs and names (old formats), or default single paddler for interleaved
      final paddlerMap = <String, String>{};
      double? firstTimestamp;
      double? lastTimestamp;

      if (isInterleaved) {
        double? t0Us;
        for (var line in dataLines) {
          final parts = line.split(',');
          if (parts.length < 7) continue;
          try {
            final tUs = int.parse(parts[0]).toDouble();
            t0Us ??= tUs;
            final tSec = (tUs - t0Us) / 1e6;
            if (firstTimestamp == null || tSec < firstTimestamp) {
              firstTimestamp = tSec;
            }
            if (lastTimestamp == null || tSec > lastTimestamp) {
              lastTimestamp = tSec;
            }
          } catch (_) {
            continue;
          }
        }
        // Single default paddler
        paddlerMap['sensor_1'] = 'Sensor 1';
      } else {
        for (var line in dataLines) {
          final parts = line.split(',');
          if (parts.length >= 5) {
            try {
              final timestamp = double.parse(parts[0]);
              final paddlerId = parts[1];
              final paddlerName = parts[2];

              if (firstTimestamp == null || timestamp < firstTimestamp) {
                firstTimestamp = timestamp;
              }
              if (lastTimestamp == null || timestamp > lastTimestamp) {
                lastTimestamp = timestamp;
              }

              if (!paddlerMap.containsKey(paddlerId)) {
                paddlerMap[paddlerId] = paddlerName;
              }
            } catch (e) {
              // Skip invalid lines
              continue;
            }
          }
        }
      }

      if (firstTimestamp == null || lastTimestamp == null) {
        return null;
      }

      // Calculate duration
      final durationSeconds = (lastTimestamp - firstTimestamp).round();
      final duration = Duration(seconds: durationSeconds);

      // Get file modification time as session date
      final sessionDate = file.lastModifiedSync();

      // Create paddler list with consistent colors (same as PaddlerProvider)
      final colors = [
        Colors.blue,
        Colors.red,
        Colors.green,
        Colors.orange,
        Colors.purple,
        Colors.teal,
        Colors.pink,
        Colors.amber,
      ];

      final paddlers = paddlerMap.entries.toList().asMap().entries.map((entry) {
        final index = entry.key;
        final paddlerEntry = entry.value;
        return Paddler(
          id: paddlerEntry.key,
          name: paddlerEntry.value,
          color: colors[index % colors.length],
          forceData: [],
          insights: [],
          position3D: PaddlePosition(x: 0, y: 0, z: 0),
          currentForce: 0.0,
          position: [0, 0],
        );
      }).toList();

      // Create session ID from filename
      final sessionId = file.path.split('/').last;

      return Session(
        id: sessionId,
        name: sessionName,
        dateTime: sessionDate,
        paddlers: paddlers,
        duration: duration,
      );
    } catch (e) {
      print('Error parsing session file: $e');
      return null;
    }
  }

  // Get session by ID (filename)
  static Future<Session?> getSessionById(String sessionId) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$sessionId');

      if (await file.exists()) {
        return await _parseSessionFromFile(file);
      }
    } catch (e) {
      print('Error getting session by ID: $e');
    }
    return null;
  }

  // Load force data from CSV file for a session
  static Future<Map<String, List<AccelDataPoint>>> loadSessionForceData(
    String sessionId,
  ) async {
    final Map<String, List<AccelDataPoint>> paddlerData = {};

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filePath = '${directory.path}/$sessionId';
      final file = File(filePath);

      print('Looking for session file at: $filePath');
      if (!await file.exists()) {
        print('File does not exist: $filePath');
        return paddlerData;
      }

      print('File exists, reading content...');

      final content = await file.readAsString();
      final lines = content
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();

      if (lines.length < 2) {
        return paddlerData;
      }

      final header = lines[0].toLowerCase();
      final isInterleaved = header.startsWith('time_us,time_dif_us,data_type');
      final useAccFormat = header.contains('acc_x');
      // Older CSVs were written with a mismatched header (e.g. `force_n,x,y`)
      // while still outputting accX/accY/accZ values in columns 3..5.
      // Treat `force_n`-headed files with 6 columns as accelerometer format too.
      final useLegacyAccFormat = !useAccFormat && header.contains('force_n');

      if (isInterleaved) {
        // Interleaved BLE schema: time_us,time_dif_us,data_type,value_1,value_2,value_3,value_4
        // data_type 0.0 => accel xyz in value_1..3
        // Map to a single paddler 'sensor_1' for now.
        double? t0Us;
        for (var line in lines.sublist(1)) {
          final parts = line.split(',');
          if (parts.length < 7) continue;
          try {
            final timeUs = int.parse(parts[0]);
            final dataType = double.parse(parts[2]);
            if (t0Us == null) t0Us = timeUs.toDouble();
            final tSec = ((timeUs.toDouble() - t0Us) / 1e6).clamp(
              0.0,
              double.infinity,
            );
            if (dataType == 0.0) {
              final ax = double.parse(parts[3]);
              final ay = double.parse(parts[4]);
              final az = double.parse(parts[5]);
              final magnitude = sqrt(ax * ax + ay * ay + az * az);
              paddlerData
                  .putIfAbsent('sensor_1', () => [])
                  .add(AccelDataPoint(time: tSec, accel: magnitude));
            }
          } catch (_) {
            continue;
          }
        }
      } else {
        for (var line in lines.sublist(1)) {
          final parts = line.split(',');
          try {
            if ((useAccFormat || useLegacyAccFormat) && parts.length >= 6) {
              final timestamp = double.parse(parts[0]);
              final paddlerId = parts[1];
              final accX = double.parse(parts[3]);
              final accY = double.parse(parts[4]);
              final accZ = double.parse(parts[5]);
              final magnitude = sqrt(accX * accX + accY * accY + accZ * accZ);
              paddlerData
                  .putIfAbsent(paddlerId, () => [])
                  .add(AccelDataPoint(time: timestamp, accel: magnitude));
            } else if (!useAccFormat && parts.length >= 4) {
              // Old format: timestamp_s, paddler_id, paddler_name, force_n [, x, y]
              final timestamp = double.parse(parts[0]);
              final paddlerId = parts[1];
              final force = double.parse(parts[3]);
              paddlerData
                  .putIfAbsent(paddlerId, () => [])
                  .add(AccelDataPoint(time: timestamp, accel: force));
            }
          } catch (e) {
            continue;
          }
        }
      }

      // Sort data points by time for each paddler
      for (var paddlerId in paddlerData.keys) {
        paddlerData[paddlerId]!.sort((a, b) => a.time.compareTo(b.time));
      }
    } catch (e) {
      print('Error loading session force data: $e');
    }

    return paddlerData;
  }

  // Delete a session by ID (filename)
  static Future<bool> deleteSession(String sessionId) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$sessionId');

      if (await file.exists()) {
        await file.delete();
        return true;
      }
      return false;
    } catch (e) {
      print('Error deleting session: $e');
      return false;
    }
  }
}
