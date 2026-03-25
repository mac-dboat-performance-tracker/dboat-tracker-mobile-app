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

      // Get unique paddler IDs and names
      final paddlerMap = <String, String>{};
      double? firstTimestamp;
      double? lastTimestamp;

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
  static Future<Map<String, List<ForceDataPoint>>> loadSessionForceData(
    String sessionId,
  ) async {
    final Map<String, List<ForceDataPoint>> paddlerData = {};

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
      final useAccFormat = header.contains('acc_x');

      for (var line in lines.sublist(1)) {
        final parts = line.split(',');
        try {
          if (useAccFormat && parts.length >= 6) {
            final timestamp = double.parse(parts[0]);
            final paddlerId = parts[1];
            final accX = double.parse(parts[3]);
            final accY = double.parse(parts[4]);
            final accZ = double.parse(parts[5]);
            final magnitude = sqrt(accX * accX + accY * accY + accZ * accZ);
            paddlerData.putIfAbsent(paddlerId, () => []).add(
              ForceDataPoint(time: timestamp, force: magnitude),
            );
          } else if (!useAccFormat && parts.length >= 4) {
            // Old format: timestamp_s, paddler_id, paddler_name, force_n [, x, y]
            final timestamp = double.parse(parts[0]);
            final paddlerId = parts[1];
            final force = double.parse(parts[3]);
            paddlerData.putIfAbsent(paddlerId, () => []).add(
              ForceDataPoint(time: timestamp, force: force),
            );
          }
        } catch (e) {
          continue;
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
