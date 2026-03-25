import 'package:flutter/material.dart';
import '../models/paddler.dart';

class PaddlerDashboard extends StatefulWidget {
  final List<Paddler> paddlers;
  final bool isRecording;

  const PaddlerDashboard({
    super.key,
    required this.paddlers,
    this.isRecording = false,
  });

  @override
  State<PaddlerDashboard> createState() => _PaddlerDashboardState();
}

class _PaddlerDashboardState extends State<PaddlerDashboard> {
  double _calculateAverageAcceleration() {
    if (widget.paddlers.isEmpty) return 0.0;
    final sum = widget.paddlers
        .map((p) => p.currentForce) // magnitude in m/s²
        .reduce((a, b) => a + b);
    return sum / widget.paddlers.length;
  }

  bool _isBelowAverage(Paddler paddler, double averageAcc) {
    if (averageAcc == 0) return false;
    final threshold = averageAcc * 0.8; // 20% below average
    return paddler.currentForce < threshold;
  }

  @override
  Widget build(BuildContext context) {
    final averageAcc = _calculateAverageAcceleration();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Average Acceleration Display
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Average |a|',
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${averageAcc.toStringAsFixed(1)} m/s²',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ],
              ),
              Icon(Icons.trending_up, size: 32, color: Colors.blue.shade700),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Paddler Cards Grid
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.0,
          ),
          itemCount: widget.paddlers.length,
          itemBuilder: (context, index) {
            final paddler = widget.paddlers[index];
            final isBelowAverage = _isBelowAverage(paddler, averageAcc);

            return _buildPaddlerCard(paddler, isBelowAverage);
          },
        ),
      ],
    );
  }

  Widget _buildPaddlerCard(Paddler paddler, bool isBelowAverage) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isBelowAverage ? Colors.red.shade300 : Colors.grey.shade200,
          width: isBelowAverage ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    paddler.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isBelowAverage
                          ? Colors.red.shade700
                          : Colors.grey.shade800,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isBelowAverage)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'LOW',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ),
              ],
            ),
            const Spacer(),
            // Acceleration Display - Centered (magnitude |a| m/s²)
            Center(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${paddler.currentForce.toStringAsFixed(1)}',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: isBelowAverage
                              ? Colors.red.shade700
                              : Colors.blue.shade700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'm/s²',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'ax ${paddler.accX.toStringAsFixed(1)} ay ${paddler.accY.toStringAsFixed(1)} az ${paddler.accZ.toStringAsFixed(1)}',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Acceleration',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
