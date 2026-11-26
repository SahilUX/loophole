# Loophole

An open-source, account-free app for the Ultrahuman Ring AIR, plus the Python tools and protocol notes it's built on. It talks to the ring over Bluetooth, with no vendor app, account or server.

**Loophole is an independent project. It is not affiliated with or endorsed by Ultrahuman.** "Ultrahuman" and "Ring AIR" are used only to say which ring it is for.

It isn't a medical device. Don't use it to make health decisions.

## What works and is tested

**This version has not run on a phone or a ring yet.** Everything below under "Seen with my ring" describes an older build from late October 2026; the code has changed a lot since then, and only the automated tests and builds below have run on it.

I have only used this with one ring, in short sessions. "Seen" below means I still have a private Bluetooth log, synced record file or screenshot showing it. None of those are published, so treat this as my word.

**Unit tested, with frames made up for the tests:**
- Decoding: history records, battery state, live heart rate, breathing samples, raw PPG frames, event log, status flags, debug and config pages, CRC
- The exact commands that may be sent
- What counts as a reading, the battery-life estimate, sleep estimate, baselines, recovery score, daily totals and worn time
- Heart rate from raw PPG, on generated signals only
- The dashboard's hiding of IDs, its refusal of other sites, and that its page reads the fields the server sends
- That the app's files ask for no backup and no location, and that its messages don't hold the ring's name

The tests and the decoders share my understanding of what each byte means. If I misread a field, both are wrong together.

**Seen with my ring, older build (late October 2026):**
- From a Mac, with the Python tools: live heart rate, breathing mode, battery state, status flags, record range, event log, and some debug pages
- From the Android app: a stored history file downloaded from the ring

**Sleep tracking is built and has unit tests, but it is not validated on a real night.** The battery on the ring I was using didn't last long enough to get through one. Anything that depends on a night of sleep is unvalidated too: overnight charts, baselines, the recovery score and sleep trends.

**Untested or unproven:**
- iOS on a real device. The project builds; I have no record of running it. Apple Health isn't offered, because it needs an entitlement that isn't there yet
- Health Connect export
- Sending the clock, interval, sensor mode, battery mode, SpO2 and raw PPG commands from my own code. I have logs of the official app sending most of them, or used them while building and kept no record
- SpO2 readings. None of my records holds one
- Breathing rate. No byte that might be one ever held a plausible value, so Loophole doesn't show it or write it to Health Connect. The CSV has the raw byte as `byte_29`
- The second temperature in history records. It equals the first in every record I have, so I don't know what it is
- CSV export, the home-screen widget, reconnecting, and staying connected overnight
- Accuracy of any reading against another device
- Finish code and size from the serial number: the layout is inferred from one ring
- What most event log labels mean (see `notes/protocol.md`)

Nothing automated covers Bluetooth or the screens.

## Where your data goes

Loophole has no server and no code that sends data to one. A release build of the Android app doesn't ask for internet or location permission. A debug build, which is what `flutter run` makes, has internet permission because Flutter's tools need it.

- Readings are stored in the app. On Android, Loophole asks the system to leave everything it stores out of cloud backups, transfers to another phone, and (from Android 16 QPR2) transfers to an iPhone. On an iPhone, it marks the readings folder as left out of backups. The app's settings, which include the ring's Bluetooth name, can still be in an iPhone backup. I haven't tested any backup or transfer, and some phone makers may not follow the Android setting.
- Readings leave the app when you export the CSV or turn on Health Connect. What happens to them after that, including any sync, is up to the app that gets them. Loophole writes heart rate, HRV, SpO2, steps and sleep to Health Connect and asks for write access only. Exporting leaves a copy of the CSV in the app's temporary folder until the next export replaces it or the system clears it.
- A ring's Bluetooth name holds its hardware address (on my ring the two match). The app shows it on the pairing screen, and `loophole-ring scan` prints it. Elsewhere the app says "your ring" and shows errors by type, and the dashboard numbers the rings. The name is stored in the app's settings and file names, and the app's system logs may hold what Bluetooth libraries write there.

## Layout

| Path | Contents |
| --- | --- |
| `app/` | The Flutter app |
| `loophole_ring/` | Python library, command line and local dashboard |
| `scripts/` | Small helpers and the pre-release checks |
| `notes/protocol.md` | What I know about the protocol, and how sure I am |
| `captures/` | Bluetooth logs. Gitignored, because they contain health data. Never commit them |

## App (Flutter, `app/`)

Android 12 or newer and iOS from one codebase. You need Flutter, and Android Studio's SDK or Xcode.

```
cd app
flutter test
flutter run                  # debug build on a connected phone
flutter build apk --release  # release build, signed with the local debug key
```

The iOS app still links HealthKit through the `health` package without Apple Health usage strings, so an App Store upload would likely be rejected until that is sorted out.

For iOS, copy `ios/Flutter/Signing.example.xcconfig` to `ios/Flutter/Signing.local.xcconfig` and put in your Apple team ID. The copy is gitignored. `flutter build ios --no-codesign` builds without it.

The icon's source is `icon/loophole.svg`. After changing it, run `swift scripts/make_icons.swift` from the repository root and redo the Android vectors in `android/app/src/main/res/drawable`.

- Today: experimental recovery score from personal baselines, live heart rate, battery, steps, worn time
- Sleep: overnight estimate with a still/restless timeline, heart rate and HRV charts, and night history
- Trends: 7 and 30 days of lowest heart rate, HRV, skin temperature, sleep and steps
- Breathe: guided paced breathing with heart rate from the ring
- Ring: battery details, battery modes, SpO2 sensing, firmware, the ring's activity log, CSV export, and writing readings to Health Connect (Android)

## Python tools

```
python3 -m venv scripts/.venv && scripts/.venv/bin/pip install -e .
scripts/.venv/bin/loophole-ring --help
scripts/.venv/bin/loophole-ring battery --name UH_XXXXXXXXXXXX   # or pick the ring in the dashboard first
scripts/.venv/bin/loophole-ring web      # then open http://127.0.0.1:8765
scripts/.venv/bin/python -m unittest discover -s tests
```

Commands that connect need a ring: pass `--name` with the name `scan` printed, or pick one in the dashboard, which saves it. They never pick the first ring nearby. If the ring is connected to a phone, it may not be found. Turn that phone's Bluetooth off or force-stop the other app.

The dashboard lists nearby rings by number and connects only to the one you pick. It saves that ring's name in `~/.config/loophole-ring/web.json` and makes the file readable only by you, and the command line uses it unless you pass `--name`. It binds to 127.0.0.1 and refuses requests that name another host or that a browser sends from another site. Other programs on your computer can still read it. Raw bytes are shown in full only for replies of a known shape in which every byte is accounted for. Acknowledgements show their first three bytes, the battery state its decoded bytes, and everything else at most its opcode and size. Your own readings are on screen, so look before you share a picture of it. Stop it with Ctrl-C; a running PPG session is stopped first.

Only a fixed list of exact commands can be sent. Firmware update and reset are not on it.

## Before a release

```
python3 scripts/check_public.py                          # IDs, personal details and health data in tracked files
python3 scripts/compare_captures.py path/to/captures     # tracked files against your own captures
scripts/.venv/bin/python scripts/mutation_check.py       # plants bugs and checks that the tests catch them
```

The first two need no packages and also work on a downloaded copy; `mutation_check.py` needs a git checkout. `compare_captures.py` reads text in screenshots only on a Mac. Neither script can find everything.

## Credit

The [Gadgetbridge](https://gadgetbridge.org/) project documented this ring before I did. These facts come from its [Ultrahuman protocol page](https://gadgetbridge.org/internals/specifics/ultrahuman-protocol/) or its Ultrahuman support, by Thomas Kuehne and the Gadgetbridge contributors: the services, commands `02`, `04`, `05`, `07`, `08`, `59`, `70`, `72`, `74`, `98`, `d1` and `d2`, the history record's size and many of its fields, and bytes 0, 5 and 6 of the battery state. Gadgetbridge and its documentation are licensed under AGPL-3.0. I didn't copy its code, text or example data.

## Third-party licences

The Dart packages are MIT, BSD or Apache-2.0. The native Android and iOS libraries are Apache-2.0, BSD-3-Clause, MIT or CC0 by their published metadata, which I read for every Android library in the release build (two inherit it from a parent project). The app has a Licences entry on the Ring screen that should list them. This is my reading, not legal advice.

## Licence

GPL-3.0-or-later. See `LICENSE`.
