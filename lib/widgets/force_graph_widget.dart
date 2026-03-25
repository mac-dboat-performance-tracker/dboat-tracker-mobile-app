import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/paddler.dart';

class ForceGraphWidget extends StatefulWidget {
  final List<Paddler> paddlers;
  final bool isRecording;

  const ForceGraphWidget({
    super.key,
    required this.paddlers,
    this.isRecording = false,
  });

  @override
  State<ForceGraphWidget> createState() => ForceGraphWidgetState();
}

class ForceGraphWidgetState extends State<ForceGraphWidget> {
  final List<List<ForceDataPoint>> _streamingData = [];
  Timer? _timer;
  double _currentTime = 0.0;
  final int _maxDataPoints =
      200; // Keep last 200 data points (20 seconds at 0.1s intervals)
  final double _updateInterval = 0.1; // Update every 0.1 seconds
  final double _xAxisWindow = 20.0; // Show 20 seconds of data
  static const double _maxYAcceleration = 25.0; // m/s²

  // Store last acceleration magnitude per paddler for smoothing
  final List<double> _lastMagnitudes = [];

  @override
  void initState() {
    super.initState();
    _initializeData();

    // Only start streaming if recording is already active
    if (widget.isRecording) {
      _startStreaming();
    }
  }

  @override
  void didUpdateWidget(ForceGraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Update data when paddlers change
    if (oldWidget.paddlers.length != widget.paddlers.length) {
      _initializeData();
    }

    // Start/stop streaming based on recording state
    if (widget.isRecording && !oldWidget.isRecording) {
      _startStreaming();
    } else if (!widget.isRecording && oldWidget.isRecording) {
      stopStreaming();
    }
  }

  void _initializeData() {
    _streamingData.clear();
    _lastMagnitudes.clear();

    for (int i = 0; i < widget.paddlers.length; i++) {
      _streamingData.add([]);
      _lastMagnitudes.add(0.0);
    }

    _currentTime = 0.0;
  }

  void _startStreaming() {
    _timer = Timer.periodic(
      Duration(milliseconds: (_updateInterval * 1000).toInt()),
      (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        setState(() {
          _currentTime += _updateInterval;

          // Use real-time acceleration magnitude from paddlers (currentForce = |a|)
          for (int i = 0; i < widget.paddlers.length; i++) {
            final paddler = widget.paddlers[i];
            double magnitude = paddler.currentForce;

            if (_lastMagnitudes.length > i) {
              final last = _lastMagnitudes[i];
              final smoothingFactor = 0.5;
              magnitude = last + (magnitude - last) * smoothingFactor;
              _lastMagnitudes[i] = magnitude;
            } else {
              _lastMagnitudes.add(magnitude);
            }

            final newPoint = ForceDataPoint(
              time: _currentTime,
              force: magnitude,
            );

            // Ensure we have enough lists
            while (_streamingData.length <= i) {
              _streamingData.add([]);
            }

            _streamingData[i].add(newPoint);

            // Keep only the last N data points (rolling window)
            if (_streamingData[i].length > _maxDataPoints) {
              _streamingData[i].removeAt(0);
            }
          }
        });
      },
    );
  }

  void stopStreaming() {
    _timer?.cancel();
    _timer = null;
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _currentTime = 0.0;
    _streamingData.clear();
    _lastMagnitudes.clear();
    _initializeData();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use fixed X-axis range that scrolls smoothly
    double minX = (_currentTime - _xAxisWindow).clamp(0.0, double.infinity);
    double maxX = _currentTime;
    if (maxX <= minX) {
      maxX = minX + _xAxisWindow;
    }

    return Container(
      height: 250,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Legend
          Wrap(
            spacing: 16,
            children: widget.paddlers.asMap().entries.map((entry) {
              final index = entry.key;
              final paddler = entry.value;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: paddler.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'P${index + 1}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          // Chart
          Expanded(
            child: LineChart(
              key: ValueKey(
                'chart_${_currentTime.toStringAsFixed(1)}_${_streamingData.fold(0, (sum, list) => sum + list.length)}',
              ),
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 50,
                  getDrawingHorizontalLine: (value) {
                    return FlLine(color: Colors.grey.shade300, strokeWidth: 1);
                  },
                ),
                titlesData: FlTitlesData(
                  show: true,
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      interval: 4,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          '${value.toInt()}s',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 10,
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: 5,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          '${value.toInt()}',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 10,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.grey.shade300),
                ),
                minX: minX,
                maxX: maxX,
                minY: 0,
                maxY: _maxYAcceleration,
                clipData: FlClipData.all(),
                lineBarsData: widget.paddlers.asMap().entries.map((entry) {
                  final index = entry.key;
                  final paddler = entry.value;
                  final dataPoints =
                      _streamingData.isNotEmpty && index < _streamingData.length
                      ? _streamingData[index]
                      : <ForceDataPoint>[];

                  // Filter data points to only show those within the visible range
                  final visiblePoints = dataPoints
                      .where(
                        (point) => point.time >= minX && point.time <= maxX,
                      )
                      .toList();

                  return LineChartBarData(
                    spots: visiblePoints.map((point) {
                      return FlSpot(point.time, point.force);
                    }).toList(),
                    isCurved: true,
                    curveSmoothness: 0.35, // Smoother curves, less glitchy
                    color: paddler.color,
                    barWidth: 3,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: paddler.color.withOpacity(0.1),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
