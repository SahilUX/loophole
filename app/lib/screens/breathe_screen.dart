import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ring/ring_controller.dart';
import '../ui/widgets.dart';

/// Paced breathing (5.5 breaths/min: 5.5 s in, 5.5 s out) while the ring streams heart rate in breathing mode.
class BreatheScreen extends StatefulWidget {
  const BreatheScreen({super.key, required this.ring});
  final RingController ring;

  @override
  State<BreatheScreen> createState() => _BreatheScreenState();
}

class _BreatheScreenState extends State<BreatheScreen>
    with SingleTickerProviderStateMixin {
  static const _cycle = Duration(milliseconds: 11000);
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _cycle,
  );
  Duration _length = const Duration(minutes: 3);
  DateTime? _started;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    _anim.dispose();
    if (widget.ring.breathRunning) widget.ring.stopBreath();
    super.dispose();
  }

  Future<void> _start() async {
    await widget.ring.startBreath(_length);
    if (!widget.ring.breathRunning) return;
    _started = DateTime.now();
    _anim.repeat();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!widget.ring.breathRunning) _finish();
      setState(() {});
    });
  }

  void _finish() {
    _tick?.cancel();
    _anim.stop();
    widget.ring.stopBreath();
    setState(() => _started = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.ring,
      builder: (context, _) {
        final running = widget.ring.breathRunning && _started != null;
        final hrs = widget.ring.breathHr;
        final left = running
            ? _length - DateTime.now().difference(_started!)
            : _length;
        final first = hrs.isEmpty
            ? null
            : hrs.take(10).map((e) => e.$2).reduce((a, b) => a + b) /
                  math.min(10, hrs.length);
        final lastAvg = hrs.length < 20
            ? null
            : hrs
                      .skip(hrs.length - 10)
                      .map((e) => e.$2)
                      .reduce((a, b) => a + b) /
                  10;
        return Scaffold(
          appBar: AppBar(title: const Text('Breathe')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _anim,
                        builder: (context, _) {
                          final v = running
                              ? math.sin(
                                          _anim.value * 2 * math.pi -
                                              math.pi / 2,
                                        ) *
                                        0.5 +
                                    0.5
                              : 0.3;
                          final inhale = _anim.value < 0.5;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 120 + 140 * v,
                                height: 120 + 140 * v,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: cs.primary.withValues(
                                    alpha: 0.18 + 0.25 * v,
                                  ),
                                  border: Border.all(
                                    color: cs.primary,
                                    width: 2,
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    widget.ring.breath != null && running
                                        ? '${widget.ring.breath!.hr}'
                                        : '',
                                    style: t.displayMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                running
                                    ? (inhale ? 'Breathe in' : 'Breathe out')
                                    : 'Ready when you are',
                                style: t.headlineSmall,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  if (running)
                    Text(
                      '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')} left'
                      '${first != null && lastAvg != null ? ' · HR ${first.round()} → ${lastAvg.round()} bpm' : ''}',
                      style: t.bodyLarge,
                    )
                  else ...[
                    if (hrs.length >= 20 && first != null && lastAvg != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Last session: heart rate ${first.round()} → ${lastAvg.round()} bpm',
                          style: t.bodyLarge,
                        ),
                      ),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('1 min')),
                        ButtonSegment(value: 3, label: Text('3 min')),
                        ButtonSegment(value: 5, label: Text('5 min')),
                      ],
                      selected: {_length.inMinutes},
                      onSelectionChanged: (s) =>
                          setState(() => _length = Duration(minutes: s.first)),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: running
                        ? OutlinedButton(
                            onPressed: _finish,
                            child: const Text('End session'),
                          )
                        : FilledButton(
                            onPressed: widget.ring.client == null
                                ? null
                                : _start,
                            child: const Text('Start'),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Keep the ring on and your hand still. ${hm(DateTime.now().millisecondsSinceEpoch ~/ 1000)}',
                    style: t.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
