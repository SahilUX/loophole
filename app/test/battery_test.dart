import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/analysis/battery.dart';

void main() {
  final t0 = DateTime(2030, 1, 15, 20);

  test('from the current draw: 30 mAh at 50% and 15 mA lasts an hour', () {
    final e = estimateBattery([
      BatterySample(t0, 50, -15000, false),
    ], cellMah: 30);
    expect(e.timeLeft, const Duration(minutes: 60));
    expect(e.label, '1 h 00 min left');
  });

  test('prefers the observed slope once there are 20+ minutes', () {
    // 60% -> 50% in 30 min = 1%/3 min -> 150 min left
    final e = estimateBattery([
      BatterySample(t0, 60, -5000, false),
      BatterySample(t0.add(const Duration(minutes: 30)), 50, -5000, false),
    ]);
    expect(e.timeLeft, const Duration(minutes: 150));
  });

  test('charging shows time to full', () {
    final e = estimateBattery([BatterySample(t0, 76, 6000, true)], cellMah: 30);
    expect(e.charging, isTrue);
    expect(e.timeLeft, const Duration(minutes: 72)); // 7.2 mAh at 6 mA
    expect(e.label, startsWith('Full in'));
  });

  test('no time left without a capacity or a slope', () {
    final e = estimateBattery([BatterySample(t0, 50, -15000, false)]);
    expect((e.timeLeft, e.label), (null, 'Estimating…'));
  });
}
