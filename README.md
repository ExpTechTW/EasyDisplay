# EazyDisplay

Menu bar app for Apple silicon MacBook Pro XDR displays. The interface is in Traditional Chinese, English, and Japanese.

- Lists connected displays with their brightness. External monitors are controlled over DDC/CI, and Apple displays through the system brightness API.
- **XDR Boost**: drives the built-in panel's backlight up to 1000 nits for SDR content. Pixels and color management are untouched; only the backlight changes.
- **Auto-brightness while boosted**: follows the ambient light sensor, like the system's auto-brightness, up to 1000 nits.
- **Monitor**: brightness, backlight and system power, display temperature, and ambient light, recorded every second into SQLite.
  - Charted as stacked small multiples over the last 5 minutes (the default), hour, day, week, or 30 days.
  - One crosshair runs through all the charts, and stretches where Boost was on are shaded.
  - Settings adds an analysis for today, 7 days, or 30 days: time boosted, backlight energy per hour or day (normal against boosted), its share of system power, average and peak brightness, time at each brightness, and temperature.
- **Brightness keys**: EazyDisplay takes them from macOS and changes the display you're working on: the one holding the frontmost window, or else the one under the pointer. That works for the built-in display (boosted or not) and for external monitors over DDC. Its own indicator appears at the top right of that display, in Liquid Glass, with the brightness in nits. ⌥⇧ steps finer. This needs Accessibility access.
- **Settings**, in a sidebar window like FreeAudio's:
  - General: language and opening at login.
  - XDR Boost: auto-brightness, turning Boost back on at launch, and thermal protection.
  - Monitor: charts, how long data is kept, and clearing it.
  - Updates and About.
- **Updates**: installs new builds from GitHub releases once they pass signature checks (the same updater as FreeAudio).

## Build

Swift is pinned in [mise.toml](mise.toml). CI and every Mac use that version, and the SDK comes from Xcode.

```sh
mise install               # once, and after mise.toml changes
scripts/build-app.sh       # → build/EazyDisplay.app, signed with your Developer ID if you have one
mise exec -- swift test
open build/EazyDisplay.app
```

Requires macOS 26+ on Apple silicon. It uses private APIs (DisplayServices, MonitorPanel, CoreBrightness, IOMobileFramebuffer properties, AppleSMC, IOAVService), so it can't be distributed through the App Store.

## Versions and releases

These follow FreeAudio, which follows DPIP.

- `scripts/version.sh` names each build:
  - **Snapshot**: `26w39a`, published from every push to `main` as a GitHub pre-release.
  - **Release**: `v26.1`, published from a tag.
  - **Build code**: `126000042`, which only ever rises.
- `.github/workflows/release.yml` builds, signs, notarizes, and publishes. `scripts/notes.sh` writes the notes from the commits, and `scripts/discord.py` announces the release.
- It needs these repository secrets, set with `scripts/set-apple-secrets.sh`:
  - `APPLE_CERTIFICATE`
  - `APPLE_CERTIFICATE_PASSWORD`
  - `APPLE_TEAM_ID`
  - `APPLE_ID`
  - `APPLE_APP_SPECIFIC_PASSWORD`
  - `DISCORD_WEBHOOK` (optional)

## Monitor data

Every second EazyDisplay records the built-in display's brightness, backlight power (SMC `PDBR`), system power (`PSTR`), hottest display temperature (`TD*`), ambient light, EDR headroom, and whether boost, the thermal limit, auto-brightness and battery power were on.

The data lives in `~/Library/Application Support/io.github.yuyu1015.EazyDisplay/Monitor.sqlite`, in two tables keyed by five-minute period:

- **`raw`**: one binary block per period (`SampleCodec`). Each reading is a Float16, delta-encoded and split into byte planes, and each block is LZMA-compressed. That averages about 4–6 bytes per second of history (about 400 KB a day). Kept for 1, 7, or 30 days.
- **`rollup`**: the period's counts, averages, extremes, and backlight and system energy, stored as small integers (about 130 bytes a period). The charts over a day and the analysis read it.

Both are kept for 30 days by default, or 90 or 365 days. That's longer than any chart or analysis range, and costs about 400 KB a day.

It uses WAL mode with two connections: a writer on its own queue, which saves the current period every 10 seconds, and a read-only reader. Each connection has a 4 MiB page cache (`PRAGMA cache_size = -4096`). Incremental auto-vacuum hands pruned space back to the file system.

## Commits

The commit message is the changelog, so the format is strict (see [commit.md](commit.md)):

```
feat(boost): follow the ambient light while boosted

New(zh-Hant): 增亮時自動亮度會依環境光調整
New(en-US): auto-brightness follows the ambient light while boosted
```

To check each commit before it's made, turn on the hook once with `git config core.hooksPath .githooks`. Pull requests are checked by `.github/workflows/ci.yml`.

## How boost works

1. It saves the current preset, brightness slider, auto-brightness setting, and backlight caps.
2. It turns off the system's auto-brightness and switches to the "Apple Display (P3-600 nits)" preset. With that preset the EDR headroom stays at 1.0, so corebrightnessd doesn't rescale the backlight for HDR content.
3. It writes `IOMFBIndicatorNitsCap`, `BLNitsCap`, `limit_max_physical_brightness` and then `IOMFBBrightnessLevel` on the built-in `IOMobileFramebufferShim`.

While boosted, macOS's own brightness slider is pinned at its maximum. That makes corebrightnessd's SDR white equal to the preset's 600-nit HDR peak, so its EDR headroom stays 1.

This matters because of HDR content. Otherwise, whenever an app shows HDR, corebrightnessd starts an EDR ramp: it rewrites the backlight for about 2 seconds and dims SDR pixels to make room, while EazyDisplay keeps writing the backlight back. That shows up as flicker. Because the slider is pinned, EazyDisplay handles the brightness keys itself.

Without auto-brightness, EazyDisplay's own slider maps to nits as `1000 × slider²`. With auto-brightness on, the target comes from the ambient light: corebrightnessd's `AggregatedLux` keeps updating while the system's own auto-brightness is off. An `AmbientFilter` (after AOSP's: fast and slow averages, a hysteresis band and a debounce) decides which light level to follow, and a curve gives its brightness. The curve starts as `AmbientLight.curve` and learns from the slider and brightness keys: each adjustment becomes a point for that lighting only, as Android does since Pie.

The backlight is held on a queue of its own (`BacklightDriver`), not the main thread. 30 times a second it reads the level once. If corebrightnessd overwrote it (wake, a preset change, True Tone), it writes it back within a tick, about 10 to 20 ms. If the display is off, it waits. On the way to a new target it moves one eased step on a log scale. Everything else runs once a second with the sensor sample, or at once for the slider and keys. Turning Boost off, quitting, or relaunching after a crash restores the saved state.

**Why 1000 nits:** on a full-white screen the panel hits a power limit at about 17.6 W, which is roughly 1100 nits. At 1000 nits, brightness doesn't depend on what is on screen.

**Thermal protection:** direct writes bypass corebrightnessd's thermal management, so EazyDisplay limits boost itself, well before the panel gets hot. Boost's ceiling follows the hottest display sensor, smoothed over about 10 seconds. It is 1000 nits up to 42 °C, falls linearly to 600 nits at 45 °C, then to 400 nits at 48 °C and above. For comparison, 5 minutes of full-white at the panel's power limit reached 41 °C.

Logs: `log stream --predicate 'subsystem == "io.github.yuyu1015.EazyDisplay"'`

`Experiments/DirectUpscalingTest.swift` is the command-line tool used to find and verify this technique.
