"""Heart rate from the ring's raw PPG stream, in pure Python (no numpy).

Method: resample one channel to a uniform 25 Hz grid using frame ticks, remove the baseline with a 1.5 s moving
average, light 3-tap smoothing, then estimate the pulse two independent ways over a 10 s window:
  * DFT peak between 40 and 180 beats a minute (Hann window, 0.01 Hz steps)
  * autocorrelation peak over the same lag range
and only report a value when both agree within AGREE_PCT and the spectral peak stands out (QUALITY_MIN).
Otherwise the window is "no reliable reading". Motion and poor contact make the two methods disagree.

Unit tested on generated signals only. I kept no recording that shows it agreeing with another measurement, so treat
it as experimental.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence

from .protocol import PPG_RATE_HZ, PpgFrame

MIN_BPM, MAX_BPM = 40.0, 180.0
AGREE_PCT = 8.0
QUALITY_MIN = 6.0
SETTLE_S = 4.0  # skipped at the start of a recording


@dataclass(frozen=True)
class HrEstimate:
    bpm: float | None  # None = no reliable reading
    dft_bpm: float
    acf_bpm: float
    quality: float  # spectral peak power / mean band power


def resample(frames: Sequence[PpgFrame], channel: int = 0, fs: float = PPG_RATE_HZ) -> list[float]:
    """Uniform series from frames, placing each frame's samples 1/fs apart ending at its tick."""
    pts: list[tuple[float, float]] = []
    step_ms = 1000.0 / fs
    for f in frames:
        n = len(f.samples)
        pts.extend((f.tick_ms - (n - 1 - i) * step_ms, float(s[channel])) for i, s in enumerate(f.samples))
    if len(pts) < 2:
        return []
    pts.sort()
    t0 = pts[0][0]
    pts = [((t - t0) / 1000.0, v) for t, v in pts]
    out, j = [], 0
    for k in range(int(pts[-1][0] * fs)):
        t = k / fs
        while j < len(pts) - 2 and pts[j + 1][0] < t:
            j += 1
        (ta, va), (tb, vb) = pts[j], pts[j + 1]
        out.append(va + (vb - va) * (t - ta) / (tb - ta) if tb > ta else va)
    return out


def _detrend(x: Sequence[float], fs: float) -> list[float]:
    w = int(fs * 1.5)
    out = []
    for i in range(len(x)):
        a, b = max(0, i - w // 2), min(len(x), i + w // 2 + 1)
        out.append(x[i] - sum(x[a:b]) / (b - a))
    return out


def _smooth(x: Sequence[float], w: int = 3) -> list[float]:
    out = []
    for i in range(len(x)):
        seg = x[max(0, i - w // 2): i + w // 2 + 1]
        out.append(sum(seg) / len(seg))
    return out


def preprocess(x: Sequence[float], fs: float = PPG_RATE_HZ) -> list[float]:
    return _smooth(_detrend(x, fs))


def _dft_peak(x: Sequence[float], fs: float) -> tuple[float, float]:
    n = len(x)
    xs = [v * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))) for i, v in enumerate(x)]
    powers: list[tuple[float, float]] = []
    f = MIN_BPM / 60
    while f <= MAX_BPM / 60 + 1e-9:
        w = 2 * math.pi * f / fs
        re = sum(v * math.cos(w * i) for i, v in enumerate(xs))
        im = sum(v * math.sin(w * i) for i, v in enumerate(xs))
        powers.append((re * re + im * im, f))
        f += 0.01
    peak, freq = max(powers)
    mean = sum(p for p, _ in powers) / len(powers)
    return freq * 60, (peak / mean if mean else 0.0)


def _acf_peak(x: Sequence[float], fs: float) -> float:
    m = sum(x) / len(x)
    y = [v - m for v in x]
    best_c, best_lag = -math.inf, 1
    for lag in range(int(fs * 60 / MAX_BPM), int(fs * 60 / MIN_BPM) + 1):
        if lag >= len(y):
            break
        c = sum(y[i] * y[i + lag] for i in range(len(y) - lag)) / (len(y) - lag)
        if c > best_c:
            best_c, best_lag = c, lag
    return 60 * fs / best_lag


def estimate_window(x: Sequence[float], fs: float = PPG_RATE_HZ) -> HrEstimate:
    """x: a preprocessed window (about 10 s)."""
    dft, quality = _dft_peak(x, fs)
    acf = _acf_peak(x, fs)
    agree = abs(dft - acf) / dft * 100 <= AGREE_PCT
    bpm = round((dft + acf) / 2, 1) if agree and quality >= QUALITY_MIN else None
    return HrEstimate(bpm, round(dft, 1), round(acf, 1), round(quality, 1))


def estimate_series(x: Sequence[float], fs: float = PPG_RATE_HZ, window_s: float = 10.0,
                    step_s: float = 5.0, settle_s: float = SETTLE_S) -> Iterable[tuple[float, HrEstimate]]:
    """Yield (window end time in s, estimate) over a raw (not yet preprocessed) series."""
    y = preprocess(x, fs)[int(settle_s * fs):]
    w, step = int(window_s * fs), int(step_s * fs)
    for s in range(0, len(y) - w + 1, step):
        yield settle_s + (s + w) / fs, estimate_window(y[s:s + w], fs)
