import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analysis/daily.dart';
import '../ring/ring_controller.dart';
import '../ui/visuals.dart';
import '../ui/widgets.dart';

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key, required this.ring});
  final RingController ring;

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ring,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final recs = widget.ring.records;
        final ns = nights(recs, days: _days);
        final totals = dailyTotals(recs, days: _days);
        final first = DateUtils.dateOnly(DateTime.now())
            .subtract(Duration(days: _days - 1));
        double x(DateTime d) => d.difference(first).inHours / 24;
        String label(double v) {
          final d = first.add(Duration(days: v.round()));
          return '${d.day}/${d.month}';
        }

        Widget nightly(
          String title,
          String unit,
          double? Function(Night) f, {
          int digits = 0,
          Color? color,
          IconData icon = Icons.show_chart,
        }) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SectionCard(
            title: title,
            icon: icon,
            color: color,
            trailing: Text(unit, style: t.bodySmall),
            child: TimeLineChart(
              points: [
                for (final n in ns)
                  if (f(n) != null) (x(n.day), f(n)!),
              ],
              minX: 0,
              maxX: (_days - 1).toDouble(),
              digits: digits,
              gap: 1.5, // connect consecutive nights only
              xLabel: label,
              color: color,
            ),
          ),
        );

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Row(
                children: [
                  const Expanded(child: Caps('Trends', color: Colors.white70)),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 7, label: Text('7 d')),
                      ButtonSegment(value: 30, label: Text('30 d')),
                    ],
                    selected: {_days},
                    onSelectionChanged: (s) => setState(() => _days = s.first),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (ns.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Nightly trends appear after a few nights wearing the ring.',
                    style: t.bodyMedium,
                  ),
                ),
              if (ns.isNotEmpty) ...[
                nightly(
                  'Lowest heart rate',
                  'bpm',
                  (n) => n.lowestHr?.toDouble(),
                  icon: Icons.favorite,
                  color: Palette.heart,
                ),
                nightly(
                  'Overnight HRV',
                  'ms',
                  (n) => n.hrv,
                  color: Palette.hrv,
                  icon: Icons.monitor_heart_outlined,
                ),
                nightly(
                  'Skin temperature',
                  '°C',
                  (n) => n.skinTemp,
                  digits: 1,
                  color: Palette.temp,
                  icon: Icons.thermostat,
                ),
                nightly(
                  'Sleep',
                  'hours',
                  (n) => n.sleep.duration.inMinutes / 60,
                  digits: 1,
                  icon: Icons.bedtime,
                  color: Palette.sleep,
                ),
              ],
              SectionCard(
                title: 'Steps',
                icon: Icons.directions_walk,
                color: Palette.steps,
                child: SizedBox(
                  height: 140,
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
                            getTitlesWidget: (v, m) =>
                                _days == 7 || v.toInt() % 5 == 0
                                ? Text(
                                    _days == 7
                                        ? weekdays[totals[v.toInt()]
                                                      .day
                                                      .weekday -
                                                  1]
                                              .substring(0, 2)
                                        : '${totals[v.toInt()].day.day}',
                                    style: t.labelSmall,
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var i = 0; i < totals.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: totals[i].steps.toDouble(),
                                color: Palette.steps,
                                width: _days == 7 ? 18 : 6,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Time wearing the ring',
                icon: Icons.timer_outlined,
                color: Palette.sleep,
                child: Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    for (final d in totals.reversed.take(7))
                      Metric(
                        weekdays[d.day.weekday - 1],
                        d.worn.inMinutes == 0
                            ? '–'
                            : (d.worn.inMinutes / 60).toStringAsFixed(1),
                        unit: 'h',
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
