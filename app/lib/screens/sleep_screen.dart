import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../analysis/daily.dart';
import '../ring/ring_controller.dart';
import '../ui/visuals.dart';
import '../ui/widgets.dart';

class SleepScreen extends StatefulWidget {
  const SleepScreen({super.key, required this.ring});
  final RingController ring;

  @override
  State<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends State<SleepScreen> {
  int? _pick; // index into nights; null = latest

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ring,
      builder: (context, _) {
        final t = Theme.of(context).textTheme;
        final ns = nights(widget.ring.records, days: 30);
        if (ns.isEmpty) {
          Widget step(IconData icon, Color c, String text) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                IconChip(icon, c, size: 38),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(text, style: const TextStyle(fontSize: 15)),
                ),
              ],
            ),
          );
          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                const Caps('Sleep', color: Colors.white70),
                const SizedBox(height: 24),
                Center(
                  child: SizedBox(
                    width: 190,
                    height: 190,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Palette.sleep.withValues(alpha: 0.45),
                            Palette.sleep.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          center: const Alignment(-0.3, -0.3),
                        ),
                      ),
                      child: const Icon(
                        Icons.bedtime,
                        size: 72,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Center(
                  child: Text(
                    'No nights yet',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 24),
                step(
                  Icons.battery_charging_full,
                  Palette.battery,
                  'Charge the ring before bed',
                ),
                step(
                  Icons.back_hand_outlined,
                  Palette.hrv,
                  'Wear it snugly on your finger',
                ),
                step(
                  Icons.phone_android,
                  Palette.sleep,
                  'Keep the ring near your phone when you want to sync',
                ),
                step(
                  Icons.wb_sunny_outlined,
                  Palette.temp,
                  'Open the app in the morning to sync your night',
                ),
              ],
            ),
          );
        }
        final i = (_pick ?? ns.length - 1).clamp(0, ns.length - 1);
        final n = ns[i];
        final rec = recovery(ns, n);
        final b = rec.baseline;
        final s = n.sleep;
        final x0 = s.start.toDouble(), x1 = s.end.toDouble();
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Row(
                children: [
                  Expanded(child: Text('Sleep', style: t.headlineSmall)),
                  IconButton(
                    onPressed: i > 0
                        ? () => setState(() => _pick = i - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    '${weekdays[n.day.weekday - 1]} ${n.day.day}/${n.day.month}',
                    style: t.titleSmall,
                  ),
                  IconButton(
                    onPressed: i < ns.length - 1
                        ? () => setState(() => _pick = i + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Metric('Time asleep', hoursMinutes(s.duration), big: true),
                    Text(
                      '${hm(s.start)} – ${hm(s.end)} · estimate',
                      style: t.bodySmall,
                    ),
                    const SizedBox(height: 14),
                    _Timeline(night: n),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 24,
                      runSpacing: 12,
                      children: [
                        Metric(
                          'Lowest HR',
                          '${n.lowestHr ?? '–'}',
                          unit: 'bpm',
                          delta:
                              b.ready &&
                                  n.lowestHr != null &&
                                  b.lowestHr != null
                              ? '${signed(n.lowestHr! - b.lowestHr!)} vs usual'
                              : null,
                        ),
                        Metric(
                          'HRV',
                          n.hrv == null ? '–' : n.hrv!.round().toString(),
                          unit: 'ms',
                          delta: b.ready && n.hrv != null && b.hrv != null
                              ? '${signed(n.hrv! - b.hrv!)} vs usual'
                              : null,
                        ),
                        Metric(
                          'Skin temp',
                          n.skinTemp == null
                              ? '–'
                              : n.skinTemp!.toStringAsFixed(1),
                          unit: '°C',
                          delta:
                              b.ready &&
                                  n.skinTemp != null &&
                                  b.skinTemp != null
                              ? '${signed(n.skinTemp! - b.skinTemp!, 1)} vs usual'
                              : null,
                        ),
                        Metric(
                          'Restless',
                          '${(n.restlessness * 100).round()}',
                          unit: '%',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Heart rate overnight',
                icon: Icons.favorite,
                color: Palette.heart,
                child: TimeLineChart(
                  points: [
                    for (final r in s.records)
                      if (r.validHr != null)
                        (r.timestamp.toDouble(), r.validHr!.toDouble()),
                  ],
                  minX: x0,
                  maxX: x1,
                  xLabel: (v) => hm(v.round()),
                  baseline: b.ready ? b.lowestHr : null,
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'HRV overnight',
                icon: Icons.monitor_heart_outlined,
                color: Palette.hrv,
                child: TimeLineChart(
                  points: [
                    for (final r in s.records)
                      if (r.validHrv != null)
                        (r.timestamp.toDouble(), r.validHrv!.toDouble()),
                  ],
                  minX: x0,
                  maxX: x1,
                  xLabel: (v) => hm(v.round()),
                  color: Theme.of(context).colorScheme.tertiary,
                  baseline: b.ready ? b.hrv : null,
                ),
              ),
              const SizedBox(height: 12),
              SectionCard(
                title: 'Last nights',
                icon: Icons.bedtime,
                color: Palette.sleep,
                child: _History(
                  nights: ns,
                  onPick: (j) => setState(() => _pick = j),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Sleep is estimated from how still you were while the ring had a heart rate. This hasn\'t been checked on a '
                'real night, and there are no sleep stages. The dashed line is your usual value from earlier nights.',
                style: t.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Still vs restless bands across the night.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.night});
  final Night night;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = night.sleep;
    final span = (s.end - s.start).clamp(1, 1 << 31);
    return SizedBox(
      height: 22,
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            for (final r in s.records)
              if (r.motion > 5 || r.steps > 0)
                Positioned(
                  left: (r.timestamp - s.start) / span * c.maxWidth,
                  top: 0,
                  bottom: 0,
                  width: (6 * 60 / span * c.maxWidth).clamp(2, c.maxWidth),
                  child: Container(color: cs.tertiary),
                ),
          ],
        ),
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.nights, required this.onPick});
  final List<Night> nights;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme.primary;
    final shown = nights.length > 14
        ? nights.sublist(nights.length - 14)
        : nights;
    final offset = nights.length - shown.length;
    return SizedBox(
      height: 150,
      child: BarChart(
        BarChartData(
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            touchCallback: (e, r) {
              if (e is FlTapUpEvent && r?.spot != null) {
                onPick(offset + r!.spot!.touchedBarGroupIndex);
              }
            },
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (v, m) =>
                    Text('${v.toInt()}h', style: t.labelSmall),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, m) => Text(
                  weekdays[shown[v.toInt()].day.weekday - 1].substring(0, 1),
                  style: t.labelSmall,
                ),
              ),
            ),
          ),
          barGroups: [
            for (var j = 0; j < shown.length; j++)
              BarChartGroupData(
                x: j,
                barRods: [
                  BarChartRodData(
                    toY: shown[j].sleep.duration.inMinutes / 60,
                    color: c,
                    width: 12,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
