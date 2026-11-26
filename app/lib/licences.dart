// Licence texts Flutter doesn't collect by itself: Loophole's own, and the native Android and iOS libraries'.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const licenceFiles = {
  'Loophole': 'GPL-3.0.txt',
  'Native libraries': 'native-libraries.txt',
  'Apache License 2.0': 'Apache-2.0.txt',
};

Stream<LicenseEntry> extraLicences() async* {
  for (final MapEntry(key: name, value: file) in licenceFiles.entries) {
    final text = await rootBundle.loadString('assets/licenses/$file');
    yield LicenseEntryWithLineBreaks([name], text);
  }
}
