import 'package:flutter/material.dart';
import '../models/paddler.dart';
import '../models/session.dart';
import 'dart:math';

class DummyData {
  static final Random _random = Random();

  // Generate dummy force data points
  static List<ForceDataPoint> generateForceData(int count) {
    return List.generate(count, (index) {
      final time = index * 2.0; // 2 seconds between points
      final baseForce = 100.0 + _random.nextDouble() * 50.0;
      final variation = sin(index * 0.5) * 20.0;
      final force = baseForce + variation;
      return ForceDataPoint(time: time, force: force.clamp(50.0, 200.0));
    });
  }

  // Generate dummy 3D paddle positions
  static PaddlePosition generatePaddlePosition(int index) {
    return PaddlePosition(
      x: 20.0 + _random.nextDouble() * 10.0 - 5.0,
      y: -15.0 + _random.nextDouble() * 10.0 - 5.0,
      z: 5.0 + _random.nextDouble() * 10.0 - 5.0,
    );
  }

  // Generate dummy insights
  static List<Insight> generateInsights(String paddlerName) {
    return [
      Insight(
        title: 'Excellent Synchronization',
        description: '$paddlerName shows 92% sync rate, above optimal range of 85-95%. Great coordination!',
        type: InsightType.positive,
      ),
      Insight(
        title: 'Power Consistency',
        description: 'Average force output is stable at 145N with only 5% variation. Maintain this rhythm.',
        type: InsightType.positive,
      ),
      Insight(
        title: 'Recovery Optimization',
        description: 'ML suggests reducing recovery by 0.15s could increase stroke rate by 3-5 spm.',
        type: InsightType.warning,
      ),
    ];
  }

  // Create dummy paddlers
  static List<Paddler> createDummyPaddlers() {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.red,
    ];
    final names = [
      'Alex Chen',
      'Maria Garcia',
      'James Wilson',
      'Sarah Kim',
    ];

    return List.generate(4, (index) {
      return Paddler(
        id: 'paddler_$index',
        name: names[index],
        color: colors[index],
        forceData: generateForceData(10),
        insights: generateInsights(names[index]),
        position3D: generatePaddlePosition(index),
      );
    });
  }

  // Create dummy sessions
  static List<Session> createDummySessions() {
    return [
      Session(
        id: 'session_1',
        name: 'Morning Practice',
        dateTime: DateTime.now().subtract(const Duration(hours: 2)),
        paddlers: createDummyPaddlers(),
        duration: const Duration(minutes: 45),
      ),
      Session(
        id: 'session_2',
        name: 'Evening Training',
        dateTime: DateTime.now().subtract(const Duration(days: 1)),
        paddlers: createDummyPaddlers(),
        duration: const Duration(minutes: 60),
      ),
      Session(
        id: 'session_3',
        name: 'Weekend Workout',
        dateTime: DateTime.now().subtract(const Duration(days: 3)),
        paddlers: createDummyPaddlers(),
        duration: const Duration(minutes: 50),
      ),
      Session(
        id: 'session_4',
        name: 'Intensive Session',
        dateTime: DateTime.now().subtract(const Duration(days: 5)),
        paddlers: createDummyPaddlers(),
        duration: const Duration(minutes: 55),
      ),
    ];
  }
}

