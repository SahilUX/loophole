import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analysis/sleep.dart';
import '../ring/protocol.dart';
import '../ring/ring_controller.dart';

/// One day's data from the ring: last night's sleep estimate and charts for HR, HRV, skin temperature and steps.
class DayScreen extends StatefulWidget {
  const DayScreen({super.key, required this.ring});
  final RingController ring;

  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final start = _day.millisecondsSinceEpoch ~/ 1000;
    final end =
        _day.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    final recs = widget.ring.records
        .where((r) => r.timestamp >= start && r.timestamp < end)
        .toList();
    final sleep = estimateSleep(widget.ring.records, _day);
    final today = DateUtils.dateOnly(DateTime.now());
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _day == today
              ? 'Today'
              : MaterialLocalizations.of(context).formatMediumDate(_day),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () =>
                setState(() => _day = _day.subtract(const Duration(days: 1))),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _day == today
                ? null
                : () =>
                      setState(() => _day = _day.add(const Duration(days: 1))),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SleepCard(sleep: sleep),
          const SizedBox(height: 12),
          if (recs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No data from the ring for this day.',
                style: t.bodyMedium,
              ),
            ),
          _ChartCard(
            title: 'Heart rate',
            unit: 'bpm',
            start: start,
            points: [
              for (final r in recs)
                if (r.validHr != null) (r.timestamp, r.validHr!.toDouble()),
            ],
          ),
          _ChartCard(
            title: 'HRV (RMSSD)',
            unit: 'ms',
            start: start,
            points: [
              for (final r in recs)
                if (r.validHrv != null) (r.timestamp, r.validHrv!.toDouble()),
            ],
          ),
          _ChartCard(
            title: 'Skin temperature',
            unit: '°C',
            start: start,
            digits: 1,
            points: [
              for (final r in recs)
                if (r.validSkinTemp != null) (r.timestamp, r.validSkinTemp!),
            ],
          ),
          _StepsCard(records: recs, start: start),
        ],
      ),
    );
  }
}

String _hm(int unix) {
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _SleepCard extends StatelessWidget {
  const _SleepCard({required this.sleep});
  final SleepEstimate? sleep;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = sleep;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bedtime_outlined, size: 20),
                const SizedBox(width: 8),
                Text('Last night · estimate', style: t.titleMedium),
                const Spacer(),
                Text('estimate', style: t.labelSmall),
              ],
            ),
            const SizedBox(height: 8),
            if (s == null)
              Text(
                'No sleep found. Wear the ring overnight and sync in the morning.',
                style: t.bodyMedium,
              )
            else ...[
              Text(
                '${s.duration.inHours} h ${s.duration.inMinutes % 60} min',
                style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text('${_hm(s.start)} – ${_hm(s.end)}', style: t.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 20,
                children: [
                  if (s.lowestHr != null) Text('Lowest HR ${s.lowestHr} bpm'),
                  if (s.avgHrv != null) Text('HRV ${s.avgHrv!.round()} ms'),
                  if (s.avgSkinTemp != null)
                    Text('Skin ${s.avgSkinTemp!.toStringAsFixed(1)} °C'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.unit,
    required this.start,
    required this.points,
    this.digits = 0,
  });
  final String title, unit;
  final int start, digits;
  final List<(int, double)> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final color = Theme.of(context).colorScheme.primary;
    final ys = points.map((p) => p.$2);
    final lo = ys.reduce((a, b) => a < b ? a : b),
        hi = ys.reduce((a, b) => a > b ? a : b);
    final avg = ys.reduce((a, b) => a + b) / points.length;
    final pad = (hi - lo).abs() < 1 ? 1.0 : (hi - lo) * 0.15;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(title, style: t.titleMedium),
                  const Spacer(),
                  Text(
                    'avg ${avg.toStringAsFixed(digits)} · ${lo.toStringAsFixed(digits)}–${hi.toStringAsFixed(digits)} $unit',
                    style: t.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                child: LineChart(
                  LineChartData(
                    minX: 0,
                    maxX: 24,
                    minY: lo - pad,
                    maxY: hi + pad,
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          getTitlesWidget: (v, m) => Text(
                            v.toStringAsFixed(digits),
                            style: t.labelSmall,
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          interval: 6,
                          getTitlesWidget: (v, m) => Text(
                            '${v.toInt().toString().padLeft(2, '0')}:00',
                            style: t.labelSmall,
                          ),
                        ),
                      ),
                    ),
                    lineTouchData: const LineTouchData(enabled: true),
                    lineBarsData: [
                      // one line per worn stretch: break where readings are more than 20 minutes apart
                      for (final seg in _segments(points))
                        LineChartBarData(
                          spots: [
                            for (final p in seg)
                              FlSpot((p.$1 - start) / 3600, p.$2),
                          ],
                          color: color,
                          barWidth: 2,
                          isCurved: false,
                          dotData: FlDotData(show: seg.length < 3),
                          belowBarData: BarAreaData(
                            show: true,
                            color: color.withValues(alpha: 0.08),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepsCard extends StatelessWidget {
  const _StepsCard({required this.records, required this.start});
  final List<Record> records;
  final int start;

  @override
  Widget build(BuildContext context) {
    final hourly = List<int>.filled(24, 0);
    for (final r in records) {
      final h = (r.timestamp - start) ~/ 3600;
      if (h >= 0 && h < 24) hourly[h] += r.steps;
    }
    final total = hourly.fold<int>(0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    final color = Theme.of(context).colorScheme.tertiary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Steps', style: t.titleMedium),
                const Spacer(),
                Text('$total', style: t.bodySmall),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: BarChart(
                BarChartData(
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: const AxisTitles(),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (v, m) => v.toInt() % 6 == 0
                            ? Text(
                                '${v.toInt().toString().padLeft(2, '0')}:00',
                                style: t.labelSmall,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var h = 0; h < 24; h++)
                      BarChartGroupData(
                        x: h,
                        barRods: [
                          BarChartRodData(
                            toY: hourly[h].toDouble(),
                            color: color,
                            width: 6,
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<List<(int, double)>> _segments(List<(int, double)> points) {
  final out = <List<(int, double)>>[];
  for (final p in points) {
    if (out.isEmpty || p.$1 - out.last.last.$1 > 20 * 60) {
      out.add([p]);
    } else {
      out.last.add(p);
    }
  }
  return out;
}
