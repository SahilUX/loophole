// Draws the home-screen widget straight onto a canvas and returns a PNG (Android shows it in an ImageView).
// Same look as the app: battery ring, heart rate, recovery orb on a dark card.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'visuals.dart';

Future<Uint8List> renderWidgetPng({
  required int? battery,
  required bool charging,
  required String batteryLeft,
  required int? hr,
  required int? recovery,
  required String status,
  bool connected = true,
  double w = 1080,
  double h = 520,
}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
  final s = h / 520; // scale

  // card
  final card = RRect.fromRectAndRadius(
    Rect.fromLTWH(0, 0, w, h),
    Radius.circular(70 * s),
  );
  c.drawRRect(
    card,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF1E1E25), Color(0xFF0A0A0D)],
      ).createShader(card.outerRect),
  );

  void text(
    String t,
    Offset at,
    double size,
    Color color, {
    FontWeight weight = FontWeight.w500,
    bool center = false,
    double spacing = 0,
    String? family,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: weight,
          letterSpacing: spacing,
          fontFamily: family,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center ? at - Offset(tp.width / 2, tp.height / 2) : at);
  }

  // header
  text(
    'LOOPHOLE',
    Offset(48 * s, 36 * s),
    26 * s,
    Palette.mute,
    spacing: 5 * s,
    family: 'monospace',
  );
  final stat = status.toUpperCase();
  final tpStat = TextPainter(
    text: TextSpan(
      text: stat,
      style: TextStyle(
        fontSize: 24 * s,
        letterSpacing: 3 * s,
        fontFamily: 'monospace',
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  text(
    stat,
    Offset(w - 48 * s - tpStat.width, 38 * s),
    24 * s,
    Palette.mute,
    spacing: 3 * s,
    family: 'monospace',
  );
  c.drawCircle(
    Offset(w - 48 * s - tpStat.width - 20 * s, 52 * s),
    8 * s,
    Paint()..color = connected ? Palette.good : Palette.mute,
  );

  final cy = 270 * s, r = 105 * s;
  final cols = [w * 0.19, w * 0.5, w * 0.81];

  // battery ring
  final bc = battery == null
      ? Palette.mute
      : battery <= 15
      ? Palette.low
      : battery <= 35
      ? Palette.fair
      : Palette.battery;
  final ring = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 18 * s
    ..strokeCap = StrokeCap.round;
  final rect = Rect.fromCircle(center: Offset(cols[0], cy), radius: r);
  c.drawArc(rect, 0, math.pi * 2, false, ring..color = Colors.white10);
  if ((battery ?? 0) > 0) {
    c.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * battery! / 100,
      false,
      ring..color = bc,
    );
  }
  text(
    charging ? '⚡' : '',
    Offset(cols[0], cy - 42 * s),
    34 * s,
    bc,
    center: true,
  );
  text(
    battery == null ? '–' : '$battery%',
    Offset(cols[0], cy + 6 * s),
    58 * s,
    Colors.white,
    weight: FontWeight.w700,
    center: true,
  );

  // heart rate
  final heart = Icons.favorite;
  final hp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(heart.codePoint),
      style: TextStyle(
        fontSize: 64 * s,
        fontFamily: heart.fontFamily,
        package: heart.fontPackage,
        color: Palette.heart,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  hp.paint(c, Offset(cols[1] - hp.width / 2, cy - 110 * s));
  text(
    hr == null ? '–' : '$hr',
    Offset(cols[1], cy + 18 * s),
    92 * s,
    Colors.white,
    weight: FontWeight.w700,
    center: true,
  );
  text(
    'BPM',
    Offset(cols[1], cy + 82 * s),
    24 * s,
    Palette.mute,
    center: true,
    spacing: 4 * s,
    family: 'monospace',
  );

  // recovery orb
  final oc = ScoreOrb.colorFor(recovery);
  c.drawCircle(
    Offset(cols[2], cy),
    r * 1.05,
    Paint()
      ..shader =
          RadialGradient(
            colors: [
              oc.withValues(alpha: 0.6),
              oc.withValues(alpha: 0.15),
              Colors.transparent,
            ],
            stops: const [0, 0.6, 1],
            center: const Alignment(-0.3, -0.35),
          ).createShader(
            Rect.fromCircle(center: Offset(cols[2], cy), radius: r * 1.05),
          ),
  );
  final orc = Rect.fromCircle(center: Offset(cols[2], cy), radius: r * 0.92);
  final arc = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 9 * s
    ..strokeCap = StrokeCap.round;
  c.drawArc(
    orc,
    math.pi * 0.75,
    math.pi * 1.5,
    false,
    arc..color = Colors.white12,
  );
  if (recovery != null) {
    c.drawArc(
      orc,
      math.pi * 0.75,
      math.pi * 1.5 * recovery / 100,
      false,
      arc..color = oc,
    );
  }
  text(
    recovery == null ? '–' : '$recovery',
    Offset(cols[2], cy),
    72 * s,
    Colors.white,
    weight: FontWeight.w700,
    center: true,
  );

  // captions
  final capY = h - 72 * s;
  for (final (i, t) in [batteryLeft, 'Heart rate', 'Recovery (exp.)'].indexed) {
    text(
      t.toUpperCase(),
      Offset(cols[i], capY),
      22 * s,
      Colors.white70,
      center: true,
      spacing: 3 * s,
      family: 'monospace',
    );
  }

  final img = await rec.endRecording().toImage(w.round(), h.round());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}
