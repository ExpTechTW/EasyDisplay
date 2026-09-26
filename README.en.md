<div align="center">

<img src=".github/assets/icon.png" width="128" alt="EasyDisplay">

# EasyDisplay

**Display brightness in the macOS menu bar: the MacBook Pro's XDR display reaches 1000 nits for everyday content, with its colors unchanged.**


[![Release](https://img.shields.io/github/v/release/ExpTechTW/EasyDisplay?label=Release&color=1B8A50)](https://github.com/ExpTechTW/EasyDisplay/releases/latest)

[![Pre-release](https://img.shields.io/github/v/tag/ExpTechTW/EasyDisplay?sort=date&label=Pre-release&color=orange)](https://github.com/ExpTechTW/EasyDisplay/releases)

[![Build](https://img.shields.io/github/actions/workflow/status/ExpTechTW/EasyDisplay/release.yml?branch=main&label=Build)](https://github.com/ExpTechTW/EasyDisplay/actions/workflows/release.yml)

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#download)

[![Discord](https://img.shields.io/discord/926545182407688273?logo=discord&logoColor=white&label=Discord&color=5865F2)](https://discord.gg/5dbHqV8ees)


[繁體中文](README.md) • **English** • [日本語](README.ja.md)


[Download](https://github.com/ExpTechTW/EasyDisplay/releases/latest) • [Changelog](https://github.com/ExpTechTW/EasyDisplay/releases) • [Report a problem](https://github.com/ExpTechTW/EasyDisplay/issues)

</div>

## What is EasyDisplay

EasyDisplay is a macOS display brightness tool that lives in the menu bar. The MacBook Pro's Liquid Retina XDR display tops out at 600 nits for everyday (SDR) content and keeps anything brighter for HDR. EasyDisplay raises the backlight directly, so everyday content can reach 1000 nits too.

It only changes the backlight: pixels aren't scaled and color management isn't touched, so colors stay as accurate as before. While boosted, brightness can also follow the ambient light and learn what you like in each lighting. External displays' brightness is adjusted from the same place.

## Screenshots

The screenshots show the Traditional Chinese interface.

<table>
<tr>
<td align="center"><img src="imgs/menu-bar.png" width="240" alt="Menu bar panel"><br>Menu bar panel: each display's brightness and a live monitor</td>
<td align="center"><img src="imgs/settings-boost.png" width="520" alt="XDR Boost"><br>XDR Boost: the switch, what the display is doing, and auto-brightness</td>
</tr>
</table>

<table>
<tr>
<td align="center"><img src="imgs/settings-auto-brightness.png" width="390" alt="Learned auto-brightness"><br>Learned auto-brightness: the curve it learned, and thermal protection</td>
<td align="center"><img src="imgs/settings-general.png" width="390" alt="General"><br>General: opening at login, brightness keys and language</td>
</tr>
<tr>
<td align="center"><img src="imgs/settings-monitor.png" width="390" alt="Monitor"><br>Monitor: brightness, backlight power and display temperature</td>
<td align="center"><img src="imgs/settings-monitor-light-power.png" width="390" alt="Monitor"><br>Monitor: ambient light and system power</td>
</tr>
<tr>
<td align="center"><img src="imgs/settings-analysis.png" width="390" alt="Analysis"><br>Analysis: time boosted, backlight energy and time at each brightness</td>
<td align="center"><img src="imgs/settings-analysis-details.png" width="390" alt="Analysis details"><br>Analysis details and how long data is kept</td>
</tr>
</table>

## What it does

| | |
|---|---|
| **XDR Boost** | Raises the built-in XDR display's backlight directly, so everyday content reaches up to 1000 nits with unchanged colors. Turning Boost off, quitting, or reopening after a crash restores the display preset, brightness and auto-brightness you had |
| **Auto-brightness while boosted** | Follows the ambient light sensor, up to 1000 nits. Brightness only moves on a real change in the light (10% brighter for 4 seconds, or 20% darker for 8), and eases smoothly instead of jumping |
| **Learns what you like** | Adjusting the slider or brightness keys while auto-brightness is on teaches it the brightness you want in that light, and only in similar light: brightening a dark room doesn't brighten daylight too. The learned curve is shown in Settings, where it can also be forgotten |
| **Thermal protection** | Driving the backlight directly bypasses macOS's own thermal management, so EasyDisplay lowers the limit itself before the panel gets hot: gradually from a display temperature of 42 °C, to 600 nits at 45 °C and 400 nits from 48 °C |
| **Brightness keys** | Takes over the keyboard's brightness keys and changes the display you're using (the one with the frontmost window, or else the one under the pointer), built-in or external, with the brightness in nits at that display's top right. Hold ⌥⇧ for finer steps |
| **External displays** | Adjust external displays' brightness from the menu bar: Apple displays through the system, others over DDC/CI |
| **Monitor** | Brightness, backlight power, system power, display temperature and ambient light are recorded every second and charted over the last 5 minutes up to 30 days. Pointing at any chart reads out every chart at that moment, and stretches spent boosted are shaded |
| **Analysis** | For today, 7 or 30 days: time boosted, backlight energy (per hour or day, normal and boosted apart), its share of the whole Mac's, average and peak brightness, time at each brightness, peak temperature and average ambient light. The data stays on this Mac for 30, 90 or 365 days, about 400 KB a day |
| **Brightness in the menu bar** | The built-in display's brightness sits beside the menu bar icon; the sun is filled while boosted |
| **Automatic updates** | Updates come from GitHub, notarized by Apple, and EasyDisplay only installs builds signed by its own developer. You can choose to get pre-releases |
| **Three languages** | 繁體中文, English and 日本語, following the system unless you choose one in Settings |

## Download

EasyDisplay needs **macOS 26 or later** on Apple silicon. XDR Boost needs a MacBook Pro with a Liquid Retina XDR display.

1. Download `EasyDisplay-<version>.zip` from [Releases](https://github.com/ExpTechTW/EasyDisplay/releases/latest), unzip it, move EasyDisplay.app to the Applications folder and open it. It's notarized by Apple, so it opens straight away.
2. The first time it opens, macOS asks for Accessibility access so EasyDisplay can take the brightness keys: allow it. You can also press Allow… in the menu bar panel or in Settings › General.
   - If no dialog appears, or you declined before, open System Settings › Privacy & Security › Accessibility and turn EasyDisplay on.
   - Without it, macOS keeps the brightness keys, and the brighten key does nothing while boosted.
3. Turn on XDR Boost in Settings › XDR Boost. To have it back after a restart, turn on Open at login in Settings › General; Turn Boost back on at launch is on by default.

EasyDisplay checks for updates when it starts and every 6 hours after, and tells you when a new version is out; Check Now in Settings › Software Update checks right away. If the menu bar icon is hidden, open EasyDisplay again (from Finder or Spotlight) to show the Settings window.

### Releases and pre-releases

| | Name | Published |
|---|---|---|
| Release | `26.1`: the year and a number | By hand |
| Pre-release | `26w39a`: the year, the week, and the week's builds | Automatically, on every push to `main`; unreviewed, and may have problems |

To try new builds early, turn on Get Pre-releases in Settings › Software Update. A release only updates to releases, and a pre-release only to pre-releases. The bottom of the menu bar panel shows the version in use, with an orange label for a pre-release and a green one for a release.

## Known limitations

- XDR Boost has only been tested on a MacBook Pro with M4 Max so far.
- While boosted, the display uses the "Apple Display (P3-600 nits)" preset, so HDR video has no highlights brighter than white. Turn Boost off to watch HDR content.
- While boosted, macOS's brightness stays at its maximum: use EasyDisplay's slider or the brightness keys instead. The brightness slider in Control Center jumps back to the maximum after you move it.
- Don't run EasyDisplay alongside other tools that drive the backlight directly, such as BetterDisplay; they would keep overwriting each other's brightness.
- External displays need DDC/CI for their brightness to be adjusted; some displays and adapters don't support it.
- EasyDisplay uses private macOS APIs. A future macOS update may break some features for a while, and it can't be distributed through the App Store.

## Development

Building EasyDisplay needs macOS 26 or later, Xcode 26 or later (for the macOS 26 SDK), and [mise](https://mise.jdx.dev): the Swift version is pinned in [mise.toml](mise.toml), the same on every Mac and in CI.

```bash
git clone https://github.com/ExpTechTW/EasyDisplay.git
cd EasyDisplay
mise install                          # install the Swift that mise.toml names
git config core.hooksPath .githooks   # check commit messages as you commit
mise exec -- swift test               # run the tests
scripts/build-app.sh                  # build build/EasyDisplay.app
open build/EasyDisplay.app
```

- `scripts/build-app.sh` signs with a certificate from your keychain: Developer ID Application first, then Apple Development. With neither, it signs ad hoc, so macOS asks for permission again after every build and the app can't update itself.
- `swift run` works too, but Accessibility access is then granted to the terminal; the bundled app is the better choice.
- Commit messages are the changelog. The format is in [commit.md](commit.md) (in Traditional Chinese), and a git hook and CI check it.
- `Experiments/DirectUpscalingTest.swift` is the command-line tool used to find and verify how boost works.

### How it works

Turning Boost on, EasyDisplay:

1. Saves the display preset, brightness slider, auto-brightness setting and backlight caps, which it restores when Boost is turned off, on quit, or when it reopens after a crash.
2. Turns the system's auto-brightness off, switches to the "Apple Display (P3-600 nits)" preset and pins macOS's brightness at its maximum.
3. Writes `IOMFBIndicatorNitsCap`, `BLNitsCap` and `limit_max_physical_brightness`, then `IOMFBBrightnessLevel` (all in 16.16 fixed-point nits) on the built-in display's `IOMobileFramebufferShim`, setting the backlight directly.

With macOS's brightness at its maximum, corebrightnessd's white is the preset's 600-nit HDR peak, so its EDR headroom stays at 1. Otherwise, whenever an app asks for HDR, corebrightnessd starts an EDR ramp: for about 2 seconds it rewrites the backlight and dims SDR pixels, while EasyDisplay keeps writing the backlight back, which shows up as flicker. Because the brightness is pinned, EasyDisplay handles the brightness keys itself.

- **Backlight**: `BacklightDriver` holds it on a queue of its own, off the main thread. The framebuffer sends a message whenever its brightness properties change, so a write from elsewhere (wake, a preset change, True Tone) is written back within about 1 ms, before it shows. If the display is off, it waits, and on wake it goes straight back to where it was; when the system dims the display before sleep, it dims along smoothly. Turning Boost on keeps the brightness on screen, following EDR headroom changes so white stays the same; turning it off waits for corebrightnessd to settle, then fades to its brightness once. On the way to a new brightness it moves one eased step on a log scale, 30 times a second. Everything else runs once a second with the sensor sample, or at once for the slider and keys.
- **Auto-brightness**: corebrightnessd's `AggregatedLux` keeps updating while the system's auto-brightness is off. `AmbientFilter` (after Android's AutomaticBrightnessController: a fast and a slow average, a hysteresis band and a debounce) decides which light level to follow, and a curve gives its brightness. The curve starts as `AmbientLight.curve`, and each adjustment is a point for its lighting (as on Android since 9). Between points it's interpolated on a log scale, beyond them it fades back to the default with a Gaussian, and it's kept monotonic outward from the newest point.
- **Why 1000 nits**: on a full-white screen the panel reaches a power limit at about 17.6 W, roughly 1100 nits. At 1000 nits, brightness doesn't depend on what's on screen.
- **Monitor data**: kept in `~/Library/Application Support/io.github.yuyu1015.EasyDisplay/Monitor.sqlite`. Each five minutes is one binary block (Float16, delta-encoded, split into byte planes, LZMA-compressed; about 4–6 bytes per second on average), plus a five-minute summary that the longer charts and the analysis read.
- **Logs**: `log stream --predicate 'subsystem == "io.github.yuyu1015.EasyDisplay"'`

| File | What's in it |
|---|---|
| `BuiltInDisplay.swift` | The built-in display: turning Boost on, off and restoring it, the target brightness, auto-brightness, the thermal limit |
| `BacklightDriver.swift`, `BuiltInFramebuffer.swift` | Holding and easing the backlight on its own queue; reading and writing the backlight properties |
| `AutoBrightness.swift`, `AmbientLight.swift` | The ambient light filter and learned curve; reading the ambient light, the default curve |
| `DisplayManager.swift`, `ExternalDisplay.swift`, `DDC.swift` | The list of displays and where brightness keys go; external displays and DDC/CI |
| `BrightnessKeys.swift`, `BrightnessOSD.swift` | Taking the brightness keys and finding the display in use; the brightness indicator |
| `DisplayPresets.swift`, `PrivateFrameworks.swift` | Display presets; DisplayServices and timeouts |
| `SensorMonitor.swift`, `SMC.swift` | Sampling every second; reading power and temperature from the SMC |
| `MonitorDatabase.swift`, `SampleCodec.swift`, `MonitorChartModel.swift` | SQLite storage, the compressed format, chart data |
| `TrayView.swift`, `SettingsWindow.swift`, `SettingsView.swift`, `MonitorCharts.swift`, `MonitorAnalysisView.swift`, `AutoCurveChart.swift`, `Components.swift` | The menu bar panel, the Settings window and its pages, charts and shared controls |
| `Update.swift`, `Updater.swift` | Automatic updates: comparing versions, downloading, verifying and replacing |
| `AppSettings.swift`, `Localization.swift` | Settings; interface languages |

### Publishing

The rules follow DPIP's: every push to `main` publishes a pre-release, and a `v<yy>.<n>` tag (such as `v26.1`) publishes a release. Every build is signed with a Developer ID and notarized by Apple; its changelog is written from the commits' entry lines (see [commit.md](commit.md)) and announced on Discord.
