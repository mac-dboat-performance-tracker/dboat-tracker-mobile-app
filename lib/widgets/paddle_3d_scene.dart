import 'package:flutter/material.dart';
import '../models/paddler.dart';

class Paddle3DScene extends StatelessWidget {
  final List<Paddler> paddlers;

  const Paddle3DScene({super.key, required this.paddlers});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 300,
      decoration: BoxDecoration(
        color: Colors.blue.shade900.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200, width: 1),
      ),
      child: Stack(
        children: [
          // Grid background
          CustomPaint(
            painter: GridPainter(),
            size: Size.infinite,
          ),
          // Paddles positioned in 3D space
          ...paddlers.asMap().entries.map((entry) {
            final index = entry.key;
            final paddler = entry.value;
            return _buildPaddle(paddler, index);
          }),
          // Angle labels at the bottom
          Positioned(
            bottom: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildAngleLabel('X', paddlers[0].position3D.x),
                  const SizedBox(width: 12),
                  _buildAngleLabel('Y', paddlers[0].position3D.y),
                  const SizedBox(width: 12),
                  _buildAngleLabel('Z', paddlers[0].position3D.z),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaddle(Paddler paddler, int index) {
    // Simulate 3D positioning by offsetting based on angles
    final xOffset = (paddler.position3D.x / 45.0) * 50.0;
    final yOffset = (paddler.position3D.y / 45.0) * 50.0;
    final zScale = 1.0 + (paddler.position3D.z / 90.0) * 0.3;

    // Position paddles in a row with some variation
    final baseX = 50.0 + (index * 60.0);
    final baseY = 150.0;

    return Positioned(
      left: baseX + xOffset,
      top: baseY + yOffset,
      child: Transform.scale(
        scale: zScale,
        child: Transform.rotate(
          angle: paddler.position3D.x * 3.14159 / 180.0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Paddle shaft (orange line)
              Container(
                width: 4,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Paddle blade (colored box)
              Container(
                width: 40,
                height: 30,
                decoration: BoxDecoration(
                  color: paddler.color,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: paddler.color.withOpacity(0.5),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    'P${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAngleLabel(String axis, double angle) {
    return Text(
      '$axis: ${angle.toStringAsFixed(1)}°',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontFamily: 'monospace',
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.shade300.withOpacity(0.3)
      ..strokeWidth = 1;

    // Draw grid lines
    const spacing = 20.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

