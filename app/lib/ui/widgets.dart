// Shared building blocks for Loophole's screens.
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'visuals.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.icon,
    this.color,
    this.trailing,
    this.onTap,
    required this.child,
    this.padding,
  });
  final String? title;
  final IconData? icon;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                Row(
                  children: [
                    if (icon != null) ...[
                      IconChip(icon!, color ?? Palette.sleep, size: 30),
                      const SizedBox(width: 10),
                    ],
                    Text(title!, style: t.titleMedium),
                    const Spacer(),
                    ?trailing,
                    if (onTap != null && trailing == null)
                      const Icon(Icons.chevron_right, size: 20),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class Metric extends StatelessWidget {
  const Metric(
    this.label,
    this.value, {
    super.key,
    this.unit = '',
    this.delta,
    this.big = false,
  });
  final String label, value, unit;
  final String? delta; // e.g. "+4 vs usual"
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty) Caps(label, size: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: (big ? t.displaySmall : t.headlineSmall)?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(unit, style: t.bodySmall),
            ],
          ],
        ),
        if (delta != null) Text(delta!, style: t.labelSmall),
      ],
    );
  }
}

/// Circular score gauge (0..100).
class ScoreRing extends StatelessWidget {
  const ScoreRing({
    super.key,
    required this.score,
    required this.label,
    this.size = 132,
  });
  final int? score;
  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = score;
    final color = s == null
        ? cs.outline
        : s >= 75
        ? const Color(0xFF34C77B)
        : s >= 55
        ? const Color(0xFFF2B33D)
        : const Color(0xFFEF5D5D);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          (s ?? 0) / 100,
          color,
          cs.surfaceContainerHighest,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                s == null ? '–' : '$s',
                style: t.displaySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              Text(label, style: t.labelMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);
  final double value;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final stroke = size.width * 0.09;
    final r = rect.deflate(stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, math.pi * 0.75, math.pi * 1.5, false, p..color = track);
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
  bool shouldRepaint(_RingPainter o) => o.value != value || o.color != color;
}

/// Line chart over a time axis; breaks the line where points are more than [gap] seconds apart.
class TimeLineChart extends StatelessWidget {
  const TimeLineChart({
    super.key,
    required this.points,
    required this.minX,
    required this.maxX,
    this.height = 140,
    this.digits = 0,
    this.xLabel,
    this.gap = 20 * 60,
    this.color,
    this.baseline,
  });
  final List<(double, double)> points; // (x, y)
  final double minX, maxX;
  final double height;
  final int digits;
  final String Function(double x)? xLabel;
  final double gap;
  final Color? color;
  final double? baseline;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('No data')),
      );
    }
    final t = Theme.of(context).textTheme;
    final c = color ?? Theme.of(context).colorScheme.primary;
    final ys = [...points.map((p) => p.$2), ?baseline];
    final lo = ys.reduce(math.min), hi = ys.reduce(math.max);
    final pad = (hi - lo).abs() < 1 ? 1.0 : (hi - lo) * 0.15;
    final segs = <List<(double, double)>>[];
    for (final p in points) {
      if (segs.isEmpty || p.$1 - segs.last.last.$1 > gap) {
        segs.add([p]);
      } else {
        segs.last.add(p);
      }
    }
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: lo - pad,
          maxY: hi + pad,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          extraLinesData: baseline == null
              ? null
              : ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: baseline!,
                      color: Theme.of(context).colorScheme.outline,
                      strokeWidth: 1,
                      dashArray: [4, 4],
                    ),
                  ],
                ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (v, m) =>
                    Text(v.toStringAsFixed(digits), style: t.labelSmall),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: xLabel != null,
                reservedSize: 22,
                interval: (maxX - minX) / 4,
                getTitlesWidget: (v, m) => v == maxX || v == minX
                    ? const SizedBox.shrink()
                    : Text(xLabel!(v), style: t.labelSmall),
              ),
            ),
          ),
          lineBarsData: [
            for (final seg in segs)
              LineChartBarData(
                spots: [for (final p in seg) FlSpot(p.$1, p.$2)],
                color: c,
                barWidth: 2,
                dotData: FlDotData(show: seg.length < 3),
                belowBarData: BarAreaData(
                  show: true,
                  color: c.withValues(alpha: 0.08),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String hm(int unix) {
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String hoursMinutes(Duration d) => '${d.inHours} h ${d.inMinutes % 60} min';

String signed(double? v, [int digits = 0]) =>
    v == null ? '' : '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(digits)}';

const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
