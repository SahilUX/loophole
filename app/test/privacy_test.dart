// Promises the app makes about data, checked against the platform files that keep them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:loophole/data/health_export.dart';
import 'package:loophole/ring/ring_controller.dart' show errorKind;

String read(String path) => File(path).readAsStringSync();

void main() {
  const main = 'android/app/src/main';

  test('Android: no backup, no transfer', () {
    final manifest = read('$main/AndroidManifest.xml');
    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
    final rules = read('$main/res/xml/data_extraction_rules.xml');
    for (final part in [
      'cloud-backup',
      'device-transfer',
      'cross-platform-transfer',
    ]) {
      final body = rules.split('<$part')[1].split('</$part>')[0];
      expect(body, isNot(contains('<include')));
      for (final d in [
        'root',
        'file',
        'database',
        'sharedpref',
        'external',
        'device_root',
        'device_file',
        'device_database',
        'device_sharedpref',
      ]) {
        expect(
          body,
          contains('<exclude domain="$d" path="." />'),
          reason: '$part $d',
        );
      }
    }
  });

  test('Android: no location and no internet permission of our own', () {
    final manifest = read('$main/AndroidManifest.xml');
    for (final p in ['ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION']) {
      for (final m in RegExp(
        '<uses-permission[^>]*$p[^>]*>',
      ).allMatches(manifest)) {
        expect(m[0], contains('tools:node="remove"'));
      }
      expect(manifest, contains(p));
    }
    expect(manifest, isNot(contains('permission.INTERNET')));
  });

  test('breathing rate is never exported', () {
    expect(healthTypes, isNot(contains(HealthDataType.RESPIRATORY_RATE)));
    expect(read('$main/AndroidManifest.xml'), isNot(contains('RESPIRATORY')));
    expect(read('lib/data/health_export.dart'), isNot(contains('byte29')));
  });

  test('consent text names everything that is written', () {
    final texts = [
      RegExp("'Writes [^']*'")
          .firstMatch(read('lib/screens/ring_screen.dart'))![0]!,
    ];
    for (final t in texts) {
      for (final word in ['heart rate', 'HRV', 'SpO2', 'steps', 'sleep']) {
        expect(t, contains(word));
      }
    }
    expect(healthTypes.length, 5);
  });

  test('iOS: the readings folder is left out of backups', () {
    final swift = read('ios/Runner/AppDelegate.swift');
    expect(swift, contains('isExcludedFromBackup = true'));
    expect(swift, contains('.applicationSupportDirectory'));
    expect(
      read('lib/data/record_store.dart'),
      contains('getApplicationSupportDirectory'),
    );
  });

  test('export file name does not hold the ring name', () {
    expect(
      read('lib/screens/ring_screen.dart'),
      contains("'\${dir.path}/loophole-export.csv'"),
    );
  });

  test('no message shows the ring name, its address or raw error text', () {
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      final text = f.readAsStringSync();
      expect(
        RegExp(r"'[^'\n]*\$(?:e\b|\{e[.}])[^'\n]*'").hasMatch(text),
        isFalse,
        reason: '${f.path}: error text in a string',
      );
      for (final m in RegExp(
        r"'[^'\n]*\$(?:ringName|\{[^}]*[rR]ingName)[^'\n]*'",
      ).allMatches(text)) {
        expect(
          m[0],
          anyOf(contains('records_'), contains('healthExportedUntil_')),
          reason: f.path,
        );
      }
    }
    // The pairing list is the one place a name is shown.
    expect(read('lib/screens/pair_screen.dart'), contains('Text(ring.name)'));
    for (final s in ['ring_screen', 'today_screen', 'sleep_screen']) {
      expect(read('lib/screens/$s.dart'), isNot(contains('ringName')));
    }
  });

  test('error text is a type name', () {
    const secret =
        'UH'
        '_invented';
    expect(errorKind(StateError(secret)), isNot(contains(secret)));
    expect(errorKind(ArgumentError(secret)), 'ArgumentError');
  });

  test('the recovery score is labelled experimental wherever it is named', () {
    for (final f in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      for (final m in RegExp(
        r"'Recovery[^']*'",
      ).allMatches(f.readAsStringSync())) {
        expect(
          m[0],
          matches(RegExp(r'experimental|\(exp\.\)')),
          reason: f.path,
        );
      }
    }
  });

  test('Apple Health is not offered without its entitlement', () {
    expect(File('ios/Runner/Runner.entitlements').existsSync(), isFalse);
    expect(read('ios/Runner/Info.plist'), isNot(contains('NSHealth')));
    expect(
      read('lib/screens/ring_screen.dart'),
      isNot(contains("'Apple Health'")),
    );
  });
}
