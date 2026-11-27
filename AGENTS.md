# Loophole

An open-source, account-free app for the Ultrahuman Ring AIR, plus the Python tools and protocol notes it is built on. It talks to the ring over Bluetooth LE, with no vendor app, account or server. It is independent and unofficial. The README says what is tested and what is not; keep its claims honest.

Stage: alpha

## Layout

- `app/`: the Flutter app (Android 12+ and iOS). Ring protocol in `app/lib/ring/`, analysis (battery, sleep, daily totals) in `app/lib/analysis/`, storage and export in `app/lib/data/`, screens in `app/lib/screens/`, tests in `app/test/`.
- `loophole_ring/`: Python library, `loophole-ring` command line and the local dashboard (`web.py`, `web.html`). Needs Python 3.11+ and `bleak`.
- `tests/`: Python unit tests. Frames in them are made up.
- `scripts/`: helpers and the pre-release checks (`check_public.py`, `compare_captures.py`, `mutation_check.py`).
- `notes/protocol.md`: what is known about the protocol and how sure it is.

## Rules

- The ring's health data is personal. Never commit Bluetooth logs, captures, synced record files, screenshots of readings, ring names, hardware addresses or device IDs. `captures/` is gitignored; keep it that way. Test frames are generated, not copied from a real ring.
- Only a fixed list of exact commands may be sent to the ring (`is_allowed` in `loophole_ring/protocol.py`, mirrored as `isAllowed` in `app/lib/ring/protocol.dart`). Firmware update and reset are not on it, and adding a command needs a test and a note in `notes/protocol.md`. Change the Python and Dart sides together.
- The decoders and the tests share one reading of each byte, so a test that passes proves consistency, not that the ring agrees. State in the PR and in `notes/protocol.md` how sure a new field is.
- Anything that needs a real ring or a phone (Bluetooth, the screens, a night of sleep) is untested until someone runs it on a device. Don't write that it works from a unit test alone.
- The app asks for no internet or location permission in a release build, and no backup of its data. A change that adds a permission, a network call or a dependency needs a stated reason and an update to the README's "Where your data goes".
- No generated attribution lines in commits or PRs. Squash-merge PRs.

## Build and test

Python (run from the repo root; these are the commands used to check this file, all passed):

```
uv venv scripts/.venv && uv pip install --python scripts/.venv/bin/python -e .   # or: python3 -m venv scripts/.venv && scripts/.venv/bin/pip install -e .
scripts/.venv/bin/python -m unittest discover -s tests        # 90 tests, about 1 second
python3 scripts/check_public.py                               # no packages needed; exits 1 on a finding
scripts/.venv/bin/python scripts/mutation_check.py python     # plants 122 bugs in a temp copy; about 4 minutes
```

`mutation_check.py` with no argument also runs the Dart half and needs `flutter` on the path.

Flutter app (not run when this file was written, because the machine had no Flutter SDK; the commands come from the README):

```
cd app && flutter test
cd app && flutter analyze
cd app && flutter run                  # debug build on a connected phone
cd app && flutter build apk --release
```

`flutter build ios --no-codesign` builds iOS without signing. For a signed iOS build, copy `app/ios/Flutter/Signing.example.xcconfig` to `Signing.local.xcconfig` (gitignored) and add your team ID. The Dart SDK is `^3.13.7` (`app/pubspec.yaml`).

Before a release, run `check_public.py`, `compare_captures.py <your captures folder>` and `mutation_check.py`.

## Conventions

- Dart follows `flutter_lints` (`app/analysis_options.yaml`). The Python package uses the standard library plus `bleak` only.
- Keep the dashboard on `127.0.0.1`, refusing other hosts and cross-site requests, and keep ring identifiers out of its output and the app's messages.
- Update `README.md` and `notes/protocol.md` when behaviour or confidence changes.
