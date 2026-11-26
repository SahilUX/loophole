import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loophole/licences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('licence page has the GPL, the native list and Apache 2.0', () async {
    final entries = await extraLicences().toList();
    expect(entries.map((e) => e.packages.single), licenceFiles.keys);
    for (final e in entries) {
      expect(e.paragraphs, isNotEmpty);
    }
  });

  test('the GPL text in the app is the repository licence', () {
    expect(
      File('assets/licenses/GPL-3.0.txt').readAsStringSync(),
      File('../LICENSE').readAsStringSync(),
    );
  });
}
