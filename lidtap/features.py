"""Features for one tap window (N x 3 gyro + N x 3 accel, high-passed, trigger at TRIG).

Everything is normalised by tap strength so a soft and a firm tap in the same zone look alike;
the sign of the twist at its peak is what should separate left from right, and the gyro/accel
ratio and decay shape what should separate top from bottom.
"""

import numpy as np

from .detector import FS, N, TRIG

TEMPLATE_LEN, TEMPLATE_STEP = 64, 4  # 80 ms of waveform shape, sampled every 5 ms
BANDS = [(0, 40), (40, 80), (80, 160), (160, 400)]
_N_TPL = (TEMPLATE_LEN // TEMPLATE_STEP) * 3
_N_HAND = 3 + 3 + 3 + 3 + 3 + 2 + 1 + len(BANDS)
N_FEATURES = _N_HAND + _N_TPL
# Per-feature weights applied after standardisation, so the long waveform template does not
# drown the hand-made features in distance-based models.
WEIGHTS = np.concatenate([np.ones(_N_HAND), np.full(_N_TPL, 0.35)])


def _bands(x):
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freqs = np.fft.rfftfreq(len(x), 1 / FS)
    e = np.array([spec[(freqs >= lo) & (freqs < hi)].sum() for lo, hi in BANDS]) + 1e-12
    return np.log(e / e.sum())


def onset(gm):
    """First sample at 25% of the window's peak twist: the tap's start, independent of the trigger threshold."""
    span = gm[:120]
    peak = span.max()
    if peak <= 0:
        return TRIG
    return int(np.argmax(span >= 0.25 * peak))


def extract(g, a):
    g = np.asarray(g, float)
    a = np.asarray(a, float)
    gm = np.linalg.norm(g, axis=1)
    am = np.linalg.norm(a, axis=1)
    o = onset(gm)
    k = o + int(np.argmax(gm[o: o + 64]))
    gp = max(gm[k], 1e-6)
    ka = max(o - 8, 0) + int(np.argmax(am[max(o - 8, 0): o + 64]))
    ap = max(am[ka], 1e-9)

    early = g[max(o - 8, 0): o + 32]
    e_g = (g ** 2).sum(0) + 1e-12
    e_a = (a ** 2).sum(0) + 1e-12
    below = np.nonzero(gm[k:] < 0.25 * gp)[0]
    decay_ms = (below[0] if len(below) else N - k) / FS * 1000

    tpl = g[k - 8: k - 8 + TEMPLATE_LEN: TEMPLATE_STEP] if k >= 8 else g[:TEMPLATE_LEN:TEMPLATE_STEP]
    tpl = np.vstack([tpl, np.zeros((TEMPLATE_LEN // TEMPLATE_STEP - len(tpl), 3))]) / gp

    return np.concatenate([
        g[k] / gp,                                   # twist direction at its peak (signed)
        early.sum(0) / (np.abs(early).sum() + 1e-9),  # net early rotation per axis (signed)
        e_g / e_g.sum(),                             # how twist energy splits across axes
        a[ka] / ap,                                  # shake direction at its peak (signed)
        e_a / e_a.sum(),                             # how shake energy splits across axes
        [np.log(gp / ap), np.log(gp)],               # twist per unit shake; tap strength
        [decay_ms / 50.0],
        _bands(gm),
        tpl.ravel(),
    ])
