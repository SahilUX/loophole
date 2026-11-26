// On-phone storage for synced history records: one JSON array per line, one file per ring. Kept in app storage.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ring/protocol.dart';

class RecordStore {
  RecordStore._(this._file);
  final File _file;

  static Future<RecordStore> open(String ringName) async {
    final dir = await getApplicationSupportDirectory();
    return RecordStore._(File('${dir.path}/records_$ringName.jsonl'));
  }

  static List<Object?> _encode(Record r) => [
    r.index,
    r.timestamp,
    r.hr,
    r.rmssdMs,
    r.spo2,
    r.pulseConfidence,
    r.skinTempC,
    r.secondTempC,
    r.motion,
    r.steps,
    r.byte28,
    r.byte29,
  ];

  static Record _decode(List<dynamic> a) => Record(
    index: a[0] as int,
    timestamp: a[1] as int,
    hr: a[2] as int,
    rmssdMs: a[3] as int,
    spo2: a[4] as int,
    pulseConfidence: a[5] as int,
    skinTempC: (a[6] as num?)?.toDouble(),
    secondTempC: (a[7] as num?)?.toDouble(),
    motion: a[8] as int,
    steps: a[9] as int,
    byte28: a[10] as int,
    byte29: a[11] as int,
  );

  Future<List<Record>> load() async {
    if (!await _file.exists()) return [];
    final out = <Record>[];
    for (final line in await _file.readAsLines()) {
      if (line.isEmpty) continue;
      try {
        out.add(_decode(jsonDecode(line) as List<dynamic>));
      } on Object {
        // skip a torn last line from an interrupted write
      }
    }
    return out;
  }

  Future<void> append(Iterable<Record> records) async {
    final sink = _file.openWrite(mode: FileMode.append);
    for (final r in records) {
      sink.writeln(jsonEncode(_encode(r)));
    }
    await sink.close();
  }

  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}
