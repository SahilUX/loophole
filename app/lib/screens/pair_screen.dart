import 'dart:async';

import 'package:flutter/material.dart';

import '../ring/ring_client.dart';
import '../ring/ring_controller.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.ring});
  final RingController ring;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final Map<String, FoundRing> _found = {};
  StreamSubscription<FoundRing>? _scan;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await _scan?.cancel();
    setState(() {
      _found.clear();
      _error = null;
    });
    if (!await RingController.ensurePermissions()) {
      setState(
        () => _error = 'Bluetooth permission is needed to find your ring.',
      );
      return;
    }
    _scan = scanRings().listen(
      (r) => setState(() => _found[r.id] = r),
      onError: (Object e) =>
          setState(() => _error = 'Scan failed (${errorKind(e)}).'),
    );
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final rings = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 32),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 7,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Loophole',
                style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Your ring, your data. No account and no server: Loophole talks to your ring over Bluetooth and stores '
                'readings in this app.',
                style: t.bodyLarge,
              ),
              const SizedBox(height: 28),
              Text('Find your ring', style: t.titleLarge),
              const SizedBox(height: 6),
              Text(
                'Keep it close to your phone. Close the Ultrahuman app first: a ring connected to another app may not '
                'show up. If it still doesn\'t, try putting it on the charger.',
                style: t.bodyMedium,
              ),
              const SizedBox(height: 24),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Expanded(
                child: rings.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Looking for rings nearby…'),
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: rings.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _RingTile(
                          ring: rings[i],
                          onUse: () => widget.ring.choose(rings[i]),
                        ),
                      ),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Scan again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingTile extends StatelessWidget {
  const _RingTile({required this.ring, required this.onUse});
  final FoundRing ring;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final signal = ring.rssi > -65
        ? 'Strong'
        : ring.rssi > -80
        ? 'Good'
        : 'Weak';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.radio_button_unchecked, size: 32),
        title: Text(ring.name),
        subtitle: Text('$signal signal'),
        trailing: FilledButton(
          onPressed: onUse,
          child: const Text('Use this ring'),
        ),
      ),
    );
  }
}
