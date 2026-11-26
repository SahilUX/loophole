import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'licences.dart';
import 'ring/ring_controller.dart';
import 'ui/visuals.dart';
import 'screens/shell.dart';
import 'screens/pair_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(extraLicences);
  final ring = RingController()..load();
  runApp(LoopholeApp(ring: ring));
}

class LoopholeApp extends StatelessWidget {
  const LoopholeApp({super.key, required this.ring});
  final RingController ring;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Loophole',
      theme: loopholeTheme(),
      themeMode: ThemeMode.dark,
      home: ListenableBuilder(
        listenable: ring,
        builder: (context, _) =>
            ring.ringId == null ? PairScreen(ring: ring) : Shell(ring: ring),
      ),
    );
  }
}
