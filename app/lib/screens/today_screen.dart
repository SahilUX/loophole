import 'package:flutter/material.dart';

import '../analysis/daily.dart';
import '../ring/ring_controller.dart';
import '../ui/visuals.dart';
import '../ui/widgets.dart' show hoursMinutes, signed, hm;
import '../ui/battery_sheet.dart';
import 'breathe_screen.dart';
import 'day_screen.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key, required this.ring, required this.openSleep});
  final RingController ring;
  final VoidCallback openSleep;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ring,
      builder: (context, _) {
        final ns = nights(ring.records, days: 21);
        final today = DateUtils.dateOnly(DateTime.now());
        final last = ns.isNotEmpty && ns.last.day == today ? ns.last : null;
        final rec = last == null ? null : recovery(ns, last);
        final start = today.millisecondsSinceEpoch ~/ 1000;
        final todays = ring.records.where((r) => r.timestamp >= start).toList();
        final hr = [
          for (final r in todays)
            if (r.validHr != null) r.validHr!.toDouble(),
        ];
        final hrv = [
          for (final r in todays)
            if (r.validHrv != null) r.validHrv!.toDouble(),
        ];
        final temp = [
          for (final r in todays)
            if (r.validSkinTemp != null) r.validSkinTemp!,
        ];
        final hourlySteps = List<double>.filled(24, 0);
        for (final r in todays) {
          final h = (r.timestamp - start) ~/ 3600;
          if (h >= 0 && h < 24) hourlySteps[h] += r.steps;
        }
        final steps = hourlySteps.fold<double>(0, (a, b) => a + b).round();
        double? avg(List<double> v) =>
            v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
        final base = last == null ? null : baselineBefore(ns, last);
        final s = ring.state;
        void openDay() => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => DayScreen(ring: ring)));

        return SafeArea(
          child: RefreshIndicator(
            onRefresh: ring.sync,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _Header(ring: ring),
                if (ring.message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      ring.message!,
                      style: const TextStyle(color: Palette.low, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: openSleep,
                  child: Column(
                    children: [
                      ScoreOrb(
                        score: rec?.score,
                        caption: rec == null
                            ? 'Recovery (experimental)'
                            : 'Recovery (experimental) · ${rec.label}',
                      ),
                      const SizedBox(height: 14),
                      if (rec == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            'Wear your ring to bed. If it records the night, an experimental score appears here. It hasn\'t been checked '
                            'against a real night.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Palette.mute),
                          ),
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _HeroStat(
                              Icons.bedtime,
                              Palette.sleep,
                              hoursMinutes(last!.sleep.duration),
                              'Sleep',
                            ),
                            _HeroStat(
                              Icons.monitor_heart_outlined,
                              Palette.hrv,
                              rec.hrvDelta == null
                                  ? '${last.hrv?.round() ?? '–'} ms'
                                  : '${signed(rec.hrvDelta)} ms',
                              rec.hrvDelta == null ? 'HRV' : 'HRV vs usual',
                            ),
                            _HeroStat(
                              Icons.favorite,
                              Palette.heart,
                              rec.hrDelta == null
                                  ? '${last.lowestHr ?? '–'} bpm'
                                  : '${signed(rec.hrDelta)} bpm',
                              rec.hrDelta == null
                                  ? 'Lowest HR'
                                  : 'Low HR vs usual',
                            ),
                          ],
                        ),
                      if (rec != null && !rec.baseline.ready)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: _CalibrationBar(nights: rec.baseline.nights),
                        ),
                    ],
                  ),
                ),
                const SectionTitle('Today'),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.4,
                  children: [
                    MetricTile(
                      icon: Icons.favorite,
                      color: Palette.heart,
                      label: 'Avg heart rate',
                      value: avg(hr)?.round().toString() ?? '–',
                      unit: 'bpm',
                      spark: hr,
                      onTap: openDay,
                    ),
                    MetricTile(
                      icon: Icons.monitor_heart_outlined,
                      color: Palette.hrv,
                      label: 'Avg HRV',
                      value: avg(hrv)?.round().toString() ?? '–',
                      unit: 'ms',
                      spark: hrv,
                      onTap: openDay,
                    ),
                    MetricTile(
                      icon: Icons.thermostat,
                      color: Palette.temp,
                      label: 'Skin temp',
                      value: avg(temp)?.toStringAsFixed(1) ?? '–',
                      unit: '°C',
                      note: base?.skinTemp != null && avg(temp) != null
                          ? '${signed(avg(temp)! - base!.skinTemp!, 1)} °C vs usual'
                          : null,
                      spark: temp,
                      onTap: openDay,
                    ),
                    MetricTile(
                      icon: Icons.directions_walk,
                      color: Palette.steps,
                      label: 'Steps',
                      value: '$steps',
                      spark: hourlySteps,
                      onTap: openDay,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: _LiveHeart(ring: ring)),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => showBatterySheet(context, ring),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 18,
                              horizontal: 8,
                            ),
                            child: Column(
                              children: [
                                BatteryRing(
                                  pct: s?.batteryPct,
                                  charging: s?.charging ?? false,
                                ),
                                const SizedBox(height: 10),
                                Caps(
                                  s == null
                                      ? 'Ring battery'
                                      : ring.batteryEstimate.label,
                                  size: 10,
                                  color: Colors.white70,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: PillButton(
                        'Breathwork',
                        icon: Icons.air,
                        onPressed: ring.client == null
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => BreatheScreen(ring: ring),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PillButton(
                        ring.syncing ? 'Syncing' : 'Sync',
                        icon: Icons.sync,
                        onPressed: ring.client == null || ring.syncing
                            ? null
                            : ring.sync,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Center(
                  child: Caps(
                    ring.records.isEmpty
                        ? 'No data yet'
                        : 'Last reading ${hm(ring.records.last.timestamp)}',
                    size: 10,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.ring});
  final RingController ring;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (ring.link) {
      LinkState.connected => ('Connected', Palette.good),
      LinkState.connecting => ('Connecting', Palette.fair),
      LinkState.searching => ('Searching', Palette.fair),
      LinkState.noRing => ('No ring', Palette.mute),
    };
    final h = DateTime.now().hour;
    final greet = h < 5
        ? 'Good night'
        : h < 12
        ? 'Good morning'
        : h < 18
        ? 'Good afternoon'
        : 'Good evening';
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Caps('Loophole', color: Colors.white70),
              const SizedBox(height: 4),
              Text(
                greet,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Palette.card,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              Icon(Icons.circle, size: 9, color: color),
              const SizedBox(width: 6),
              Caps(label, color: Colors.white, size: 10),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat(this.icon, this.color, this.value, this.label);
  final IconData icon;
  final Color color;
  final String value, label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Caps(label, size: 9),
      ],
    ),
  );
}

class _CalibrationBar extends StatelessWidget {
  const _CalibrationBar({required this.nights});
  final int nights;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          const IconChip(Icons.tune, Palette.sleep, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Learning your baseline'),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: nights / 3,
                    minHeight: 5,
                    color: Palette.sleep,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Caps('$nights/3 nights', color: Colors.white),
        ],
      ),
    ),
  );
}

class _LiveHeart extends StatelessWidget {
  const _LiveHeart({required this.ring});
  final RingController ring;

  @override
  Widget build(BuildContext context) {
    final hr = ring.liveRunning ? ring.liveHr?.hr : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          children: [
            TickDial(
              value: hr?.toDouble(),
              min: 40,
              max: 160,
              color: Palette.heart,
              size: 150,
              center: BigValue(hr == null ? '–' : '$hr', unit: 'bpm', size: 30),
              caption: ring.liveRunning ? 'Live' : 'Heart rate',
            ),
            const SizedBox(height: 4),
            PillButton(
              ring.liveRunning ? 'Stop' : 'Measure',
              icon: ring.liveRunning ? Icons.stop : Icons.favorite,
              color: ring.liveRunning
                  ? Palette.cardHi
                  : Palette.heart.withValues(alpha: 0.25),
              onPressed: ring.client == null
                  ? null
                  : (ring.liveRunning ? ring.stopLiveHr : ring.startLiveHr),
            ),
          ],
        ),
      ),
    );
  }
}
