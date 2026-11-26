import 'package:flutter/material.dart';

import '../ring/ring_controller.dart';
import 'ring_screen.dart';
import 'sleep_screen.dart';
import 'today_screen.dart';
import 'trends_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key, required this.ring});
  final RingController ring;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final ring = widget.ring;
    final pages = [
      TodayScreen(ring: ring, openSleep: () => setState(() => _tab = 1)),
      SleepScreen(ring: ring),
      TrendsScreen(ring: ring),
      RingScreen(ring: ring),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.bedtime_outlined),
            selectedIcon: Icon(Icons.bedtime),
            label: 'Sleep',
          ),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Trends'),
          NavigationDestination(
            icon: Icon(Icons.circle_outlined),
            selectedIcon: Icon(Icons.circle),
            label: 'Ring',
          ),
        ],
      ),
    );
  }
}
