import 'package:flutter/material.dart';

import '../ring/ring_controller.dart';
import 'visuals.dart';

/// Tap the battery ring: charge details, the battery-life estimate and the battery's own temperature.
void showBatterySheet(BuildContext context, RingController ring) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Palette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => ListenableBuilder(
      listenable: ring,
      builder: (context, _) {
        final s = ring.state;
        final est = ring.batteryEstimate;
        Widget row(IconData icon, Color c, String label, String value) =>
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  IconChip(icon, c, size: 36),
                  const SizedBox(width: 14),
                  Expanded(child: Caps(label)),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              BatteryRing(
                pct: s?.batteryPct,
                charging: s?.charging ?? false,
                size: 120,
              ),
              const SizedBox(height: 12),
              Text(
                est.label,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (est.basis.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Caps('estimated ${est.basis}', size: 9),
                ),
              const SizedBox(height: 16),
              if (s != null) ...[
                row(
                  s.microamps >= 0 ? Icons.bolt : Icons.trending_down,
                  s.microamps >= 0 ? Palette.battery : Palette.fair,
                  s.microamps >= 0 ? 'Charging current' : 'Current draw',
                  '${(s.microamps.abs() / 1000).toStringAsFixed(1)} mA',
                ),
                if (s.millivolts != null)
                  row(
                    Icons.electric_bolt_outlined,
                    Palette.oxygen,
                    'Voltage',
                    '${(s.millivolts! / 1000).toStringAsFixed(2)} V',
                  ),
                row(
                  Icons.device_thermostat,
                  Palette.temp,
                  'Battery temperature',
                  '${s.tempC} °C',
                ),
                if (s.cellMah != null)
                  row(
                    Icons.battery_full,
                    Palette.mute,
                    'Cell capacity',
                    '${s.cellMah} mAh',
                  ),
              ] else
                const Text(
                  'Waiting for the ring…',
                  style: TextStyle(color: Palette.mute),
                ),
            ],
          ),
        );
      },
    ),
  );
}
