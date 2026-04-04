import 'dart:async';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/paddler.dart';

class HistoricalForceGraphWidget extends StatefulWidget {
  final List<Paddler> paddlers;
  final Map<String, List<AccelDataPoint>> historicalData;
  final Function(List<Paddler>)? onReplayUpdate;

  /// Called every replay tick with the current replay time in seconds.
  final void Function(double timeSec)? onReplayTick;

  const HistoricalForceGraphWidget({
    super.key,
    required this.paddlers,
    required this.historicalData,
    this.onReplayUpdate,
    this.onReplayTick,
  });

  @override
  State<HistoricalForceGraphWidget> createState() =>
      _HistoricalForceGraphWidgetState();
}

class _HistoricalForceGraphWidgetState
    extends State<HistoricalForceGraphWidget> {
  /// Data revealed so far, one list per paddler.
  final List<List<AccelDataPoint>> _streamingData = [];

  /// All session data, pre-loaded once.
  final List<List<AccelDataPoint>> _fullHistoricalData = [];

  /// Per-paddler insertion cursor so each tick only appends new points (O(1)).
  final List<int> _replayIndices = [];

  Timer? _timer;
  double _replayTime = 0.0;
  double _maxReplayTime = 0.0;
  bool _isReplaying = false;

  static const double _updateInterval = 0.1; // seconds per tick

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
    _timer?.cancel();
    _streamingData.clear();
    _fullHistoricalData.clear();
    _replayIndices.clear();
    _replayTime = 0.0;
    _maxReplayTime = 0.0;
    _isReplaying = false;

    for (final paddler in widget.paddlers) {
      final pts = widget.historicalData[paddler.id] ?? [];
      _fullHistoricalData.add(List.from(pts));
      _streamingData.add([]);
      _replayIndices.add(0);
      if (pts.isNotEmpty && pts.last.time > _maxReplayTime) {
        _maxReplayTime = pts.last.time;
      }
    }

    _startReplay();
  }

  void _startReplay() {
    if (_isReplaying || _fullHistoricalData.isEmpty) return;
    _isReplaying = true;

    _timer = Timer.periodic(
      Duration(milliseconds: (_updateInterval * 1000).toInt()),
      (timer) {
        if (!mounted || !_isReplaying) {
          timer.cancel();
          return;
        }

        setState(() {
          _replayTime += _updateInterval;

          // Append new points for each paddler using the insertion cursor.
          for (
            int i = 0;
            i < _fullHistoricalData.length && i < widget.paddlers.length;
            i++
          ) {
            final fullData = _fullHistoricalData[i];
            final currentData = _streamingData[i];
            while (_replayIndices[i] < fullData.length &&
                fullData[_replayIndices[i]].time <= _replayTime) {
              currentData.add(fullData[_replayIndices[i]]);
              _replayIndices[i]++;
            }
          }
        });

        // Fire tick callback outside setState so the parent can call its own setState.
        widget.onReplayTick?.call(_replayTime);

        // Paddler-force callback (kept for backward compat).
        if (widget.onReplayUpdate != null) {
          final updated = <Paddler>[];
          for (
            int i = 0;
            i < widget.paddlers.length && i < _fullHistoricalData.length;
            i++
          ) {
            final fullData = _fullHistoricalData[i];
            AccelDataPoint? cur;
            for (final p in fullData.reversed) {
              if (p.time <= _replayTime) {
                cur = p;
                break;
              }
            }
            updated.add(widget.paddlers[i].copyWith(
              currentForce: cur?.accel ?? 0.0,
              position: cur != null ? [0, 0] : widget.paddlers[i].position,
            ));
          }
          if (updated.length == widget.paddlers.length) {
            widget.onReplayUpdate!(updated);
          }
        }

        if (_replayTime >= _maxReplayTime) {
          _isReplaying = false;
          timer.cancel();
        }
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
    // Always show the full session timeline from 0 to session end.
    final maxX = _maxReplayTime > 0 ? _maxReplayTime : 60.0;

    // Adaptive bottom-axis interval: aim for ~6 labels.
    final rawInterval = (maxX / 6).ceilToDouble();
    final axisInterval = rawInterval < 1 ? 1.0 : rawInterval;

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
                    'P${entry.key + 1}',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 5,
                  getDrawingHorizontalLine: (value) =>
                      FlLine(color: Colors.grey.shade300, strokeWidth: 1),
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
                      interval: axisInterval,
                      getTitlesWidget: (value, meta) => Text(
                        '${value.toInt()}s',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: 5,
                      getTitlesWidget: (value, meta) => Text(
                        '${value.toInt()}',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: Colors.grey.shade300),
                ),
                minX: 0,
                maxX: maxX,
                minY: 0,
                maxY: 25,
                clipData: FlClipData.all(),
                lineBarsData: widget.paddlers.asMap().entries.map((entry) {
                  final index = entry.key;
                  final paddler = entry.value;
                  final pts =
                      index < _streamingData.length ? _streamingData[index] : <AccelDataPoint>[];
                  return LineChartBarData(
                    spots: pts.map((p) => FlSpot(p.time, p.accel)).toList(),
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: paddler.color,
                    barWidth: 2,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: paddler.color.withValues(alpha: 0.08),
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
