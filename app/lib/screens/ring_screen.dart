import 'dart:io';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../ring/protocol.dart';
import '../ring/ring_controller.dart';
import '../ui/battery_sheet.dart';
import '../ui/visuals.dart';
import '../ui/widgets.dart';

class RingScreen extends StatelessWidget {
  const RingScreen({super.key, required this.ring});
  final RingController ring;

  static const _modes = {
    BatteryMode.turbo: ('Turbo', 'Chill and Critical both off.'),
    BatteryMode.chill: ('Chill', 'Chill on, Critical off.'),
    BatteryMode.critical: (
      'Critical battery',
      'Critical on. The ring may refuse live heart rate.',
    ),
  };

  Future<void> _export(BuildContext context) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/loophole-export.csv');
    final b = StringBuffer(
      'time_utc,index,hr,rmssd_ms,spo2,pulse_confidence,skin_temp_c,second_temp_c,motion,steps,byte_28,byte_29\n',
    );
    for (final r in ring.records) {
      b.writeln(
        [
          DateTime.fromMillisecondsSinceEpoch(
            r.timestamp * 1000,
            isUtc: true,
          ).toIso8601String(),
          r.index,
          r.hr,
          r.rmssdMs,
          r.spo2,
          r.pulseConfidence,
          r.skinTempC ?? '',
          r.secondTempC ?? '',
          r.motion,
          r.steps,
          r.byte28,
          r.byte29,
        ].join(','),
      );
    }
    await f.writeAsString(b.toString());
    await SharePlus.instance.share(
      ShareParams(files: [XFile(f.path)], subject: 'Loophole data'),
    );
  }

  Future<void> _forget(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Forget this ring?'),
        content: const Text('Readings already stored in the app are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok == true) await ring.forget();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ring,
      builder: (context, _) {
        final s = ring.state;
        final connected = ring.client != null;
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Palette.mute, width: 7),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your ring',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Caps(
                          ring.identity?.finishCode == null
                              ? 'No details yet'
                              : [
                                  if (ring.identity!.finishCode != null)
                                    'Finish ${ring.identity!.finishCode}',
                                  if (ring.identity!.size != null)
                                    'Size ${ring.identity!.size}',
                                ].join(' · '),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Center(
                child: GestureDetector(
                  onTap: () => showBatterySheet(context, ring),
                  child: BatteryRing(
                    pct: s?.batteryPct,
                    charging: s?.charging ?? false,
                    size: 170,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Chip(
                    icon: Icons.circle,
                    color: connected ? Palette.good : Palette.mute,
                    text: connected ? 'Connected' : 'Not connected',
                  ),
                  const SizedBox(width: 8),
                  if (ring.firmware != null)
                    _Chip(
                      icon: Icons.memory,
                      color: Palette.mute,
                      text: 'FW ${ring.firmware}',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: Caps(
                  s == null
                      ? 'Waiting for the ring'
                      : '${ring.batteryEstimate.label} · tap the ring for details',
                  color: Colors.white70,
                ),
              ),
              const SectionTitle('Battery mode'),
              Row(
                children: [
                  for (final m in BatteryMode.values) ...[
                    if (m != BatteryMode.values.first)
                      const SizedBox(width: 10),
                    Expanded(
                      child: _ModeCard(
                        mode: m,
                        selected: ring.mode == m,
                        onTap: connected ? () => ring.setMode(m) : null,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (ring.mode != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    _modes[ring.mode]!.$2,
                    style: const TextStyle(color: Palette.mute, fontSize: 13),
                  ),
                ),
              const SectionTitle('Sensors & sharing'),
              _ToggleCard(
                icon: Icons.water_drop,
                color: Palette.oxygen,
                title: 'Blood oxygen (SpO2)',
                subtitle: 'Sends the command Gadgetbridge uses for SpO2 sensing. Untested here.',
                value: ring.spo2On ?? false,
                onChanged: connected && ring.spo2On != null
                    ? ring.setSpo2
                    : null,
              ),
              const SizedBox(height: 12),
              // Apple Health needs an entitlement this project doesn't have yet.
              if (Platform.isAndroid)
                _ToggleCard(
                  icon: Icons.favorite,
                  color: Palette.heart,
                  title: 'Health Connect',
                  subtitle: ring.healthStatus ?? 'Writes heart rate, HRV, SpO2, steps and sleep, for other apps to use. Untested.',
                  value: ring.healthOn,
                  onChanged: ring.setHealth,
                ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 12),
                _ToggleCard(
                  icon: Icons.nights_stay_outlined,
                  color: Palette.sleep,
                  title: 'Run in the background',
                  subtitle: ring.backgroundAllowed == true
                      ? 'Allowed by Android. Syncing overnight is untested.'
                      : 'Ask Android to let Loophole run with the screen off. Untested overnight.',
                  value: ring.backgroundAllowed ?? false,
                  onChanged: ring.backgroundAllowed == true
                      ? null
                      : (_) => ring.allowBackground(),
                ),
              ],
              const SectionTitle('More'),
              Card(
                child: Column(
                  children: [
                    _Action(
                      Icons.history,
                      Palette.sleep,
                      'Ring activity log',
                      connected
                          ? () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => _EventsScreen(ring: ring),
                              ),
                            )
                          : null,
                    ),
                    _Action(
                      Icons.ios_share,
                      Palette.steps,
                      'Export my data (${ring.records.length} readings)',
                      ring.records.isEmpty ? null : () => _export(context),
                    ),
                    if (Platform.isAndroid)
                      _Action(
                        Icons.widgets_outlined,
                        Palette.temp,
                        'Add widget to home screen',
                        () async {
                          await ring.updateWidget(force: true);
                          await HomeWidget.requestPinWidget(
                            androidName: 'RingWidgetProvider',
                          );
                        },
                      ),
                    _Action(
                      Icons.sync,
                      Palette.hrv,
                      'Sync now',
                      connected ? ring.sync : null,
                    ),
                    _Action(
                      Icons.description_outlined,
                      Palette.mute,
                      'Licences',
                      () => showLicensePage(
                        context: context,
                        applicationName: 'Loophole',
                        applicationLegalese: 'GPL-3.0-or-later. Not affiliated with or endorsed by Ultrahuman.',
                      ),
                    ),
                    _Action(
                      Icons.link_off,
                      Palette.low,
                      'Use a different ring',
                      () => _forget(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Loophole talks to your ring directly over Bluetooth. No account and no server. Your readings stay in this '
                'app\'s storage unless you export them or turn on sharing above. Open source under GPL-3.0. Not affiliated '
                'with or endorsed by Ultrahuman.',
                style: TextStyle(color: Palette.mute, fontSize: 12),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: Palette.card,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 6),
        Caps(text, color: Colors.white, size: 10),
      ],
    ),
  );
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.mode, required this.selected, this.onTap});
  final BatteryMode mode;
  final bool selected;
  final VoidCallback? onTap;

  static const _look = {
    BatteryMode.turbo: (Icons.rocket_launch, Palette.temp, 'Turbo'),
    BatteryMode.chill: (Icons.spa, Palette.hrv, 'Chill'),
    BatteryMode.critical: (Icons.battery_alert, Palette.low, 'Critical'),
  };

  @override
  Widget build(BuildContext context) {
    final (icon, color, name) = _look[mode]!;
    return Material(
      color: selected ? color.withValues(alpha: 0.18) : Palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? color : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Icon(icon, color: selected ? color : Palette.mute, size: 28),
              const SizedBox(height: 8),
              Caps(name, color: selected ? Colors.white : Palette.mute),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          IconChip(icon, color, size: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(color: Palette.mute, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged, activeTrackColor: color),
        ],
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action(this.icon, this.color, this.title, this.onTap);
  final IconData icon;
  final Color color;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: IconChip(icon, color, size: 34),
    title: Text(title),
    trailing: const Icon(Icons.chevron_right, color: Palette.mute),
    onTap: onTap,
    enabled: onTap != null,
  );
}

class _EventsScreen extends StatefulWidget {
  const _EventsScreen({required this.ring});
  final RingController ring;

  @override
  State<_EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<_EventsScreen> {
  bool _all = false;

  @override
  void initState() {
    super.initState();
    widget.ring.loadEvents();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ring,
      builder: (context, _) {
        final evs = widget.ring.events
            .where(
              (e) =>
                  e.code != null &&
                  e.valid &&
                  (_all || friendlyEvent(e.code) != null),
            )
            .toList();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Ring activity'),
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(24),
              child: Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'What most of these mean hasn\'t been checked.',
                  style: TextStyle(color: Palette.mute, fontSize: 12),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() => _all = !_all),
                child: Text(_all ? 'Simple' : 'All'),
              ),
            ],
          ),
          body: widget.ring.events.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView.separated(
                  itemCount: evs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = evs[i];
                    final d = DateTime.fromMillisecondsSinceEpoch(
                      e.time * 1000,
                    );
                    return ListTile(
                      dense: true,
                      title: Text(friendlyEvent(e.code) ?? eventName(e.code)),
                      subtitle: _all && friendlyEvent(e.code) != null
                          ? Text(eventName(e.code))
                          : null,
                      trailing: Text('${d.day}/${d.month} ${hm(e.time)}'),
                    );
                  },
                ),
        );
      },
    );
  }
}
