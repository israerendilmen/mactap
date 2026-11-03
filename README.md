# LidTap

**Tap your MacBook lid.** LidTap turns the edges of your MacBook's display into buttons, with no extra
hardware. Tap a corner of the screen and it switches desktops, plays your music or hides everything
in a meeting.

It works by listening to the motion sensor inside your MacBook. A tap on the lid twists the laptop
slightly about its hinge; the sensor feels that twist about 800 times a second, and a small model
trained on *your* taps works out which part of the screen you tapped. Everything runs on your Mac:
no network access, no account, nothing leaves the machine.

Made by [Yemcube (@yem.cube)](https://www.instagram.com/yem.cube).

- [What a tap can do](#what-a-tap-can-do)
- [Install](#install)
- [Getting good taps](#getting-good-taps)
- [Which Macs work](#which-macs-work)
- [License](#license)
- [For developers](#for-developers)

## What a tap can do

LidTap splits the display into zones: 2×2 by default, or 2×3 and 3×3. Each zone does one thing, and
you choose which.

| Action | What it does |
|---|---|
| **Desktop Left / Right** | Switch to the previous or next desktop (Space) |
| **Play / Pause, Next, Previous** | Control whatever is playing: Music, Spotify, YouTube |
| **New Note** | Open a fresh note in Notes |
| **Open App** | Launch an app, or bring it to the front if it's already open |
| **Privacy Guard** | Mid-meeting and someone walks in? One tap mutes every microphone, turns your meeting camera off (Zoom, Teams, Webex, Google Meet) and hides the screen. Tap again or click to come back, with your mic restored exactly as it was |

The default 2×2 layout: top-left **Desktop Left**, top-right **Desktop Right**, bottom-left
**Play / Pause**, bottom-right **Privacy Guard**.

LidTap ignores the bumps that aren't taps: typing, clicking, scrolling, moving the pointer, moving the
lid, and knocks on the desk.

## Install

1. Download **LidTap-macOS.zip** from the [latest release](https://github.com/harsha20599/lidtap/releases/latest).
2. Unzip it and drag **LidTap.app** to Applications.
3. The first time, **right-click LidTap → Open** (it isn't notarized yet), then confirm.
   If macOS still refuses, open System Settings → Privacy & Security and click **Open Anyway**.
4. A hand icon appears in the menu bar, and Settings opens.
5. Allow **Accessibility** when asked (System Settings → Privacy & Security → Accessibility). Desktop
   switching and music keys need it. **Input Monitoring** is optional: it lets LidTap tell typing from
   tapping more precisely.
6. Click **Calibrate**. Tap the dot in each highlighted zone a few times (about two minutes), then let it
   record 20 seconds of everyday bumps: typing, clicking, nudging the laptop. That's it.

**Updating:** replace the app in Applications. Your calibration and settings are kept. After an update,
switch LidTap off and on again in the Accessibility list.

## Getting good taps

- **A quick, light flick** with a fingertip on the dot near each zone's corner. Never press hard: you
  don't need force, and pressing on a display can leave marks.
- **Wait for the screen to settle** between taps (about half a second).
- During calibration the meter says **Good tap**, **A little crisper** or **Gentler is fine**. Aim for green.
- Too many misreads? Settings → Training shows how reliable each zone is; **Calibrate Again** adds taps
  where they're needed. Settings → Detection has the minimum tap strength.

With crisp taps on a 2×2 grid, LidTap read 95% of taps correctly in our testing. Taps it isn't sure
about are ignored rather than guessed.

## Which Macs work

- An Apple Silicon MacBook **with the motion sensor**: MacBook Air or Pro with M2 or later, or the
  14"/16" MacBook Pro with M1 Pro or M1 Max.
- **Not** the M1 MacBook Air, the 13" M1 MacBook Pro, desktop Macs or Intel Macs: they have no motion sensor.
- macOS 14 Sonoma or later.

LidTap reads a sensor Apple doesn't document, so a future macOS update could change or break it.

## License

Free to use, change, tinker with and share under the [LidTap License](LICENSE): MIT, plus two rules.

1. **If you share anything built on LidTap publicly** (an app, a fork, a video or post showing your
   work), **credit "Based on LidTap by Yemcube"** with a link to Instagram
   [@yem.cube](https://www.instagram.com/yem.cube). Private use needs no credit.
2. **Commercial use needs approval first.** Selling it, putting it in a paid product or service, or
   using it in a company's products or advertising: message [@yem.cube](https://www.instagram.com/yem.cube)
   on Instagram.

LidTap is not affiliated with or endorsed by Apple.

---

# For developers

| Folder | What's in it |
|---|---|
| [`LidTapApp/`](LidTapApp) | The macOS menu bar app (Swift, SwiftUI) and its tests. Start with its [README](LidTapApp/README.md) |
| [`lidtap/`](lidtap), [`PROTOTYPE.md`](PROTOTYPE.md) | The original Python prototype: a browser GUI with live sensor traces, calibration and model comparison |
| [`LidTap.md`](LidTap.md) | How the detection and recognition work, end to end |
| [`reports/`](reports), [`research_notes/`](research_notes) | The research behind the approach: sensor access, prior art, signal processing and ML |
| [`tools/imu_probe.py`](tools/imu_probe.py) | A minimal probe that reads the motion and lid-angle sensors |

**Build the app** (needs the Xcode Command Line Tools):

```bash
LidTapApp/scripts/build.sh
```

It compiles with `swiftc`, assembles `LidTapApp/build/LidTap.app`, signs it ad hoc with the Hardened Runtime and
installs it to `~/Applications`. `--no-install` skips the install. To sign for distribution, set
`LIDTAP_SIGN_ID="Developer ID Application: …"` and notarize the result with `xcrun notarytool`.

**Run the tests:**

```bash
LidTapApp/scripts/test.sh
```

That runs the ML, detector, app-logic and UI suites with no side effects. The Python prototype has its own
hardware-free tests: `python -m unittest tests.test_prototype` from the repo root. `hardware`, `actions`,
`guard` and `e2e` suites drive the real system (switch Spaces, mute the mic, open apps), so run
them only when you aren't using the Mac.

**How it works, briefly:** the app reads the accelerometer and gyroscope through IOKit HID
(`AppleSPUHIDDevice`, ~800 Hz), high-pass filters the gyro, and triggers on an adaptive threshold.
Each tap becomes a 200 ms window and 70 features (shape, timing, axis ratios and a resampled template),
classified by a k-nearest-neighbours, logistic-regression or nearest-centroid model, whichever
cross-validates best on your own data. Taps far from anything it has learned, or below its confidence
floor, are rejected. Credit for the sensor work goes to [yamete](https://github.com/chipcolate/yamete),
[apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) and
[LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor); see `reports/` for the full list.
