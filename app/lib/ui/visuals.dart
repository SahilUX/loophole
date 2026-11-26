// Loophole's visual language: black canvas, soft cards, a colour per metric, gauges instead of bare numbers.
import 'dart:math' as math;

import 'package:flutter/material.dart';

abstract final class Palette {
  static const bg = Color(0xFF070708);
  static const card = Color(0xFF17171A);
  static const cardHi = Color(0xFF222226);
  static const line = Color(0xFF2C2C31);
  static const mute = Color(0xFF8E8E96);
  static const heart = Color(0xFFFF5A6E);
  static const hrv = Color(0xFF3FD8C2);
  static const temp = Color(0xFFFFA445);
  static const sleep = Color(0xFF7C83FF);
  static const steps = Color(0xFF5ED36A);
  static const battery = Color(0xFF5ED36A);
  static const oxygen = Color(0xFF4FA8FF);
  static const good = Color(0xFF34C77B);
  static const fair = Color(0xFFF2B33D);
  static const low = Color(0xFFEF5D5D);
}

ThemeData loopholeTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Palette.sleep,
      brightness: Brightness.dark,
    ).copyWith(surface: Palette.bg, primary: Palette.sleep),
    scaffoldBackgroundColor: Palette.bg,
    cardTheme: CardThemeData(
      color: Palette.card,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Color(0xFF0E0E10),
      indicatorColor: Palette.cardHi,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
  );
}

/// Small uppercase, letter-spaced label ("RESTING HR").
class Caps extends StatelessWidget {
  const Caps(this.text, {super.key, this.color, this.size = 11});
  final String text;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontFamily: 'monospace',
      fontSize: size,
      letterSpacing: 1.6,
      color: color ?? Palette.mute,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// Rounded square with a coloured icon.
class IconChip extends StatelessWidget {
  const IconChip(this.icon, this.color, {super.key, this.size = 40});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(size * 0.3),
    ),
    child: Icon(icon, color: color, size: size * 0.55),
  );
}

/// Big number with a small unit.
class BigValue extends StatelessWidget {
  const BigValue(
    this.value, {
    super.key,
    this.unit = '',
    this.size = 30,
    this.color,
  });
  final String value, unit;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Text(
        value,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w600,
          color: color,
          height: 1.1,
        ),
      ),
      if (unit.isNotEmpty) ...[
        const SizedBox(width: 3),
        Text(
          unit,
          style: TextStyle(fontSize: size * 0.42, color: Palette.mute),
        ),
      ],
    ],
  );
}

/// Tile: icon chip, label, value, optional note ("+4 vs usual") and a tiny sparkline.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.unit = '',
    this.note,
    this.spark = const [],
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label, value, unit;
  final String? note;
  final List<double> spark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconChip(icon, color, size: 34),
                const Spacer(),
                if (spark.length > 1)
                  SizedBox(
                    width: 56,
                    height: 22,
                    child: Sparkline(spark, color),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            BigValue(value, unit: unit, size: 26),
            const SizedBox(height: 4),
            Caps(label),
            if (note != null) ...[
              const SizedBox(height: 4),
              Text(note!, style: TextStyle(fontSize: 12, color: color)),
            ],
          ],
        ),
      ),
    ),
  );
}

class Sparkline extends StatelessWidget {
  const Sparkline(this.values, this.color, {super.key});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _SparkPainter(values, color));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.v, this.color);
  final List<double> v;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1 : hi - lo;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = i / (v.length - 1) * s.width,
          y = s.height - (v[i] - lo) / span * s.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.v != v;
}

/// Glowing orb with the score in the middle (recovery hero).
class ScoreOrb extends StatelessWidget {
  const ScoreOrb({
    super.key,
    required this.score,
    required this.caption,
    this.size = 210,
  });
  final int? score;
  final String caption;
  final double size;

  static Color colorFor(int? s) => s == null
      ? Palette.sleep
      : s >= 75
      ? Palette.good
      : s >= 55
      ? Palette.fair
      : Palette.low;

  @override
  Widget build(BuildContext context) {
    final c = colorFor(score);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  c.withValues(alpha: 0.55),
                  c.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.55, 1.0],
                center: const Alignment(-0.25, -0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: c.withValues(alpha: 0.25),
                  blurRadius: 60,
                  spreadRadius: 4,
                ),
              ],
            ),
          ),
          CustomPaint(
            size: Size.square(size * 0.92),
            painter: _ArcPainter((score ?? 0) / 100, c),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                score == null ? '–' : '$score',
                style: TextStyle(
                  fontSize: size * 0.27,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
              const SizedBox(height: 6),
              Caps(caption, color: Colors.white70),
            ],
          ),
        ],
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.value, this.color);
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(6);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      r,
      math.pi * 0.75,
      math.pi * 1.5,
      false,
      p..color = Colors.white12,
    );
    if (value > 0) {
      canvas.drawArc(
        r,
        math.pi * 0.75,
        math.pi * 1.5 * value.clamp(0, 1),
        false,
        p..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_ArcPainter o) => o.value != value || o.color != color;
}

/// Tick-mark dial (like a speedometer) with the current value highlighted.
class TickDial extends StatelessWidget {
  const TickDial({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.color,
    required this.center,
    this.caption = '',
    this.size = 150,
  });
  final double? value;
  final double min, max;
  final Color color;
  final Widget center;
  final String caption;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size * 0.78,
    child: CustomPaint(
      painter: _TickPainter(
        value == null ? null : ((value! - min) / (max - min)).clamp(0, 1),
        color,
      ),
      child: Padding(
        padding: EdgeInsets.only(top: size * 0.22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [center, if (caption.isNotEmpty) Caps(caption)],
        ),
      ),
    ),
  );
}

class _TickPainter extends CustomPainter {
  _TickPainter(this.frac, this.color);
  final double? frac;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 41;
    final c = Offset(size.width / 2, size.width / 2);
    final rOut = size.width / 2 - 2, rIn = rOut - 12;
    for (var i = 0; i < n; i++) {
      final t = i / (n - 1);
      final a = math.pi * 0.8 + t * math.pi * 1.4;
      final on = frac != null && t <= frac!;
      final major = i % 10 == 0;
      final p = Paint()
        ..color = on ? color.withValues(alpha: 0.35 + 0.65 * t) : Colors.white12
        ..strokeWidth = major ? 3 : 2
        ..strokeCap = StrokeCap.round;
      final r1 = major ? rIn - 4 : rIn;
      canvas.drawLine(
        c + Offset(math.cos(a), math.sin(a)) * r1,
        c + Offset(math.cos(a), math.sin(a)) * rOut,
        p,
      );
    }
    if (frac != null) {
      final a = math.pi * 0.8 + frac! * math.pi * 1.4;
      canvas.drawCircle(
        c + Offset(math.cos(a), math.sin(a)) * (rOut - 6),
        6,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TickPainter o) => o.frac != frac || o.color != color;
}

/// Battery shown as a ring with a bolt when charging.
class BatteryRing extends StatelessWidget {
  const BatteryRing({
    super.key,
    required this.pct,
    required this.charging,
    this.size = 92,
  });
  final int? pct;
  final bool charging;
  final double size;

  Color get color => pct == null
      ? Palette.mute
      : pct! <= 15
      ? Palette.low
      : pct! <= 35
      ? Palette.fair
      : Palette.battery;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: (pct ?? 0) / 100,
            strokeWidth: size * 0.09,
            strokeCap: StrokeCap.round,
            backgroundColor: Colors.white10,
            color: color,
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              charging ? Icons.bolt : Icons.battery_std,
              color: color,
              size: size * 0.22,
            ),
            Text(
              pct == null ? '–' : '$pct%',
              style: TextStyle(
                fontSize: size * 0.2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Thermometer-style scale: where today's value sits, with a marker for the usual value.
class RangeBar extends StatelessWidget {
  const RangeBar({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    this.usual,
    this.colors = const [
      Color(0xFF4FA8FF),
      Palette.hrv,
      Palette.temp,
      Palette.low,
    ],
  });
  final double? value, usual;
  final double min, max;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      double x(double v) => ((v - min) / (max - min)).clamp(0, 1) * c.maxWidth;
      return SizedBox(
        height: 28,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 11,
              child: Container(
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: LinearGradient(
                    colors: [for (final k in colors) k.withValues(alpha: 0.7)],
                  ),
                ),
              ),
            ),
            if (usual != null)
              Positioned(
                left: x(usual!) - 1,
                top: 4,
                child: Container(width: 2, height: 20, color: Colors.white54),
              ),
            if (value != null)
              Positioned(
                left: x(value!) - 9,
                top: 5,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: Palette.bg, width: 3),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Pill-shaped action button with caps label ("START BREATHWORK").
class PillButton extends StatelessWidget {
  const PillButton(
    this.label, {
    super.key,
    this.icon,
    this.onPressed,
    this.color,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Palette.card,
    shape: const StadiumBorder(),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 18,
                color: onPressed == null ? Palette.mute : Colors.white,
              ),
              const SizedBox(width: 8),
            ],
            Caps(
              label,
              color: onPressed == null ? Palette.mute : Colors.white,
              size: 12,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Section heading above a group of cards.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
    child: Row(
      children: [
        Text(
          text,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}
