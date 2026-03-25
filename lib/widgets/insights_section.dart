import 'package:flutter/material.dart';
import '../models/paddler.dart';

class InsightsSection extends StatelessWidget {
  final List<Paddler> paddlers;

  const InsightsSection({super.key, required this.paddlers});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'AI-Powered Insights',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 12),
        ...paddlers.expand((paddler) {
          return [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                paddler.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ),
            ...paddler.insights.map((insight) {
              return _buildInsightCard(insight, paddler.color);
            }),
            const SizedBox(height: 16),
          ];
        }).toList(),
      ],
    );
  }

  Widget _buildInsightCard(Insight insight, Color paddlerColor) {
    Color backgroundColor;
    Color iconColor;
    IconData icon;

    switch (insight.type) {
      case InsightType.positive:
        backgroundColor = Colors.green.shade50;
        iconColor = Colors.green;
        icon = Icons.check_circle;
        break;
      case InsightType.warning:
        backgroundColor = Colors.orange.shade50;
        iconColor = Colors.orange;
        icon = Icons.warning;
        break;
      case InsightType.info:
        backgroundColor = Colors.blue.shade50;
        iconColor = Colors.blue;
        icon = Icons.info;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: iconColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: iconColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  insight.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: iconColor,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  insight.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

