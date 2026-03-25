import 'package:flutter/material.dart';

class Paddler {
  final String id; // MAC address
  final String name;
  final Color color;
  final List<ForceDataPoint> forceData;
  final List<Insight> insights;
  final PaddlePosition position3D;
  /// Acceleration magnitude (m/s²), used for graph; derived from accX, accY, accZ.
  double currentForce;
  List<int> position; // [X, Y] — legacy, kept for compatibility
  double accX; // Acceleration x (m/s²)
  double accY;
  double accZ;

  Paddler({
    required this.id,
    required this.name,
    required this.color,
    required this.forceData,
    required this.insights,
    required this.position3D,
    this.currentForce = 0.0,
    List<int>? position,
    this.accX = 0.0,
    this.accY = 0.0,
    this.accZ = 0.0,
  }) : position = position ?? [0, 0];

  Paddler copyWith({
    String? id,
    String? name,
    Color? color,
    List<ForceDataPoint>? forceData,
    List<Insight>? insights,
    PaddlePosition? position3D,
    double? currentForce,
    List<int>? position,
    double? accX,
    double? accY,
    double? accZ,
  }) {
    return Paddler(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      forceData: forceData ?? this.forceData,
      insights: insights ?? this.insights,
      position3D: position3D ?? this.position3D,
      currentForce: currentForce ?? this.currentForce,
      position: position ?? this.position,
      accX: accX ?? this.accX,
      accY: accY ?? this.accY,
      accZ: accZ ?? this.accZ,
    );
  }
}

class ForceDataPoint {
  final double time; // in seconds
  final double force; // in Newtons

  ForceDataPoint({required this.time, required this.force});
}

class Insight {
  final String title;
  final String description;
  final InsightType type;

  Insight({
    required this.title,
    required this.description,
    required this.type,
  });
}

enum InsightType {
  positive,
  warning,
  info,
}

class PaddlePosition {
  final double x; // angle in degrees
  final double y; // angle in degrees
  final double z; // angle in degrees

  PaddlePosition({
    required this.x,
    required this.y,
    required this.z,
  });
}

