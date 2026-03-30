import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/paddler.dart';

class HistoricalForceGraphWidget extends StatefulWidget {
  final List<Paddler> paddlers;
  final Map<String, List<AccelDataPoint>> historicalData;
  final Function(List<Paddler>)? onReplayUpdate;

  const HistoricalForceGraphWidget({
    super.key,
    required this.paddlers,
    required this.historicalData,
    this.onReplayUpdate,
  });

  @override
  State<HistoricalForceGraphWidget> createState() =>
      _HistoricalForceGraphWidgetState();
}

class _HistoricalForceGraphWidgetState
    extends State<HistoricalForceGraphWidget> {
  final List<List<AccelDataPoint>> _streamingData = [];
  Timer? _timer;
  double _currentTime = 0.0;
  final double _updateInterval = 0.1; // Update every 0.1 seconds
  final double _xAxisWindow = 20.0; // Show 20 seconds of data
  final int _maxDataPoints = 200; // Keep last 200 data points

  // Replay state
  final List<List<AccelDataPoint>> _fullHistoricalData = [];
  double _replayTime = 0.0;
  double _maxReplayTime = 0.0;
  bool _isReplaying = false;

  @override
  void initState() {
    super.initState();
    _loadHistoricalData();
  }

  @override
  void didUpdateWidget(HistoricalForceGraphWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.historicalData != widget.historicalData ||
        oldWidget.paddlers.length != widget.paddlers.length) {
      _loadHistoricalData();
    }
  }

  void _loadHistoricalData() {
    _streamingData.clear();
    _fullHistoricalData.clear();
    _currentTime = 0.0;
    _replayTime = 0.0;
    _maxReplayTime = 0.0;

    // Load full historical data for replay
    for (var paddler in widget.paddlers) {
      final dataPoints = widget.historicalData[paddler.id] ?? [];
      _fullHistoricalData.add(List.from(dataPoints));

      // Find max time in all data
      if (dataPoints.isNotEmpty) {
        final maxTime = dataPoints
            .map((p) => p.time)
            .reduce((a, b) => a > b ? a : b);
        if (maxTime > _maxReplayTime) {
          _maxReplayTime = maxTime;
        }
      }
    }

    // Initialize streaming data with empty lists
    for (int i = 0; i < widget.paddlers.length; i++) {
      _streamingData.add([]);
    }

    // Start replay
    _startReplay();
  }

  void _startReplay() {
    if (_isReplaying || _fullHistoricalData.isEmpty) {
      return;
    }

    _isReplaying = true;
    _replayTime = 0.0;
    _currentTime = 0.0;

    // Clear streaming data to start fresh
    for (int i = 0; i < _streamingData.length; i++) {
      _streamingData[i].clear();
    }

    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(milliseconds: (_updateInterval * 1000).toInt()),
      (timer) {
        if (!mounted || !_isReplaying) {
          timer.cancel();
          return;
        }

        setState(() {
          _replayTime += _updateInterval;
          _currentTime = _replayTime;

          // For each paddler, add all points that are at or before current replay time
          for (
            int i = 0;
            i < _fullHistoricalData.length && i < widget.paddlers.length;
            i++
          ) {
            final fullData = _fullHistoricalData[i];
            if (fullData.isEmpty) continue;

            final currentData = _streamingData[i];

            // Add all points that are at or before replay time and not already added
            for (var point in fullData) {
              // Only add points up to current replay time
              if (point.time <= _replayTime) {
                // Check if we already have this point (within small tolerance)
                final exists = currentData.any(
                  (p) => (p.time - point.time).abs() < 0.001,
                );
                if (!exists) {
                  currentData.add(point);
                }
              } else {
                // Data is sorted, so we can break once we pass replay time
                break;
              }
            }

            // Sort by time
            currentData.sort((a, b) => a.time.compareTo(b.time));

            // Keep only points within visible window (rolling window)
            final minVisibleTime = (_currentTime - _xAxisWindow).clamp(
              0.0,
              double.infinity,
            );
            currentData.removeWhere((p) => p.time < minVisibleTime);

            // Keep only last N points to prevent memory issues
            if (currentData.length > _maxDataPoints) {
              currentData.removeRange(0, currentData.length - _maxDataPoints);
            }
          }

          // Update paddler data based on current replay time
          if (widget.onReplayUpdate != null) {
            final updatedPaddlers = <Paddler>[];
            for (
              int i = 0;
              i < widget.paddlers.length && i < _fullHistoricalData.length;
              i++
            ) {
              final paddler = widget.paddlers[i];
              final fullData = _fullHistoricalData[i];

              // Find the most recent data point at or before current replay time
              AccelDataPoint? currentPoint;
              for (var point in fullData.reversed) {
                if (point.time <= _replayTime) {
                  currentPoint = point;
                  break;
                }
              }

              // Update paddler with current force value
              final updatedPaddler = paddler.copyWith(
                currentForce: currentPoint?.accel ?? 0.0,
                position: currentPoint != null ? [0, 0] : paddler.position,
              );
              updatedPaddlers.add(updatedPaddler);
            }

            // Call callback with updated paddlers
            if (updatedPaddlers.length == widget.paddlers.length) {
              widget.onReplayUpdate!(updatedPaddlers);
            }
          }

          // Stop replay when we've reached the end
          if (_replayTime >= _maxReplayTime) {
            _isReplaying = false;
            timer.cancel();
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Calculate window for replay
    double minX, maxX;
    if (_currentTime <= 0) {
      // Initial state - show a window
      minX = 0.0;
      maxX = _xAxisWindow;
    } else if (_currentTime <= _xAxisWindow) {
      // Growing window phase
      minX = 0.0;
      maxX = _currentTime;
    } else {
      // Scrolling window phase
      minX = _currentTime - _xAxisWindow;
      maxX = _currentTime;
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
                'historical_chart_${_replayTime.toStringAsFixed(1)}_${_streamingData.fold(0, (sum, list) => sum + list.length)}',
              ),
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 5,
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
                maxY: 25, // m/s² acceleration magnitude
                clipData: FlClipData.all(),
                lineBarsData: widget.paddlers.asMap().entries.map((entry) {
                  final index = entry.key;
                  final paddler = entry.value;
                  final dataPoints =
                      _streamingData.isNotEmpty && index < _streamingData.length
                      ? _streamingData[index]
                      : <AccelDataPoint>[];

                  // Filter data points to only show those within the visible range
                  final visiblePoints = dataPoints
                      .where(
                        (point) => point.time >= minX && point.time <= maxX,
                      )
                      .toList();

                  return LineChartBarData(
                    spots: visiblePoints.map((point) {
                      return FlSpot(point.time, point.accel);
                    }).toList(),
                    isCurved: true,
                    curveSmoothness: 0.35,
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
