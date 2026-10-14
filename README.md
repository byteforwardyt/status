# Status

<p align="center"><img src="Status/Supporting%20Files/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Status"></p>

Status is a macOS menu bar monitor. It shows CPU, GPU, memory, disk, network, sensors, battery, and Bluetooth. No account, no subscription, no telemetry.

<p align="center">
  <a href="https://github.com/byteforwardyt/status/releases/latest/download/Status.dmg"><img src="docs/images/download-macos.svg" alt="Download Status for macOS" height="52"></a>
</p>

[Download Status.dmg](https://github.com/byteforwardyt/status/releases/latest/download/Status.dmg) · macOS 12 or newer · Apple silicon and Intel · [All releases](https://github.com/byteforwardyt/status/releases)

The release disk image is signed and notarized.

## Features

- **Menu bar.** Turn on the modules you want. A health dot is on by default. Minimal mode hides the other icons and keeps the dot.
- **CPU, GPU, memory, disk.** Usage, temperature, pressure, swap, throughput, and S.M.A.R.T.
- **Network.** Upload and download speed, totals, the active interface, Wi-Fi signal, packet loss, latency, peak speeds, daily totals, and which apps used the network.
- **Connections.** Live TCP and UDP connections. Each app is marked Apple, Developer ID, or unverified. This does not ask for an admin password.
- **Sensors and fans.** Temperatures, voltages, power, a temperature chart, and an optional cooling mode.
- **Battery and Bluetooth.** Level, health, cycles, power use, and battery levels of connected devices.
- **Clock.** Time in more than one time zone.
- **Health.** Short notes when the Mac is hot, busy, or low on disk. Alerts, a 7-day history, and a Mac Health widget.
- **Shortcuts.** Ask for Mac health, temperature, CPU, or memory. This needs macOS 13.
- **Storage hints.** On demand, Status measures caches and developer folders. It does not scan Desktop, Documents, or Downloads.

macOS widgets need macOS 14. The Mac Health widget is one of them.

## What changed from Stats

Status is a fork of [Stats](https://github.com/exelban/stats) by Serhiy Mytrovtsiy. The same modules are still there. The fork changes how the app behaves and what it adds.

**The updater, donation prompts, and cloud Remote module are gone.** Status does not check a server for updates, and it does not send analytics.

**The interface is easier to scan.** Popups use a glass background on current macOS. Settings uses cards, with an icon next to each module. Numbers can be green, yellow, orange, or red. That coloring is a switch in app settings, and it can be turned off.

**It does less work when you are not looking at it.** Process lists come from the kernel (`libproc`) instead of launching `ps`. When the full sensor list is not on screen, Status reads only the sensors a widget or alert needs. Most readers pause while every display is asleep. Network, disk, and battery keep running, because their totals and alerts depend on the next reading. The primary network interface is cached for 5 seconds instead of being looked up on every tick.

**Network shows more than speed.** Packet loss, latency, jitter, session peaks, 62 days of daily totals, 31 days of per-app totals, Wi-Fi signal quality, and a connections window that checks each app's code signature.

**Heat has its own controls.** A CPU and GPU temperature widget, a temperature bar, and cooling mode. Cooling mode is off until you turn it on. At the temperature you pick (70, 75, 80, 85, or 90°C) it sets every fan to full speed, then hands control back to macOS after the CPU has cooled by 8 degrees. Fan control needs the SMC helper. macOS asks for an admin password once to install it.

**Health is a first-class view, not a pile of graphs.** It explains the likely reason the Mac is hot or busy, stores 7 days of per-minute averages and peaks, and can sit in the menu bar as one dot. Shortcuts and the Mac Health widget answer from readings Status already has. They do not send those readings anywhere.

## Install

1. Download [Status.dmg](https://github.com/byteforwardyt/status/releases/latest/download/Status.dmg).
2. Open it and drag **Status** into **Applications**.
3. Open Status. The first launch shows Status Setup.
4. After that, Status stays in the menu bar. It does not show a Dock icon unless you turn that on in settings.

Click a menu bar icon to open its popup. The sliders button in the popup opens that module's settings. The health dot opens a short health summary. From there you can open History.

Wi-Fi network name needs Location permission. Bluetooth battery levels need Bluetooth permission.

## Build from source

You need Xcode.

```bash
make install
```

That archives a Release build, signs it, copies it to `/Applications/Status.app`, and opens it. The project does not include an Apple team id. Set your own team in the Xcode project, and add that team id to `exportOptions.plist`, before running this.

To compile without signing:

```bash
xcodebuild -scheme Status -destination 'platform=macOS' -configuration Release archive CODE_SIGNING_ALLOWED=NO -archivePath build/Status.xcarchive
```

`make build` also notarizes. It expects a notarytool keychain profile named `STATUS_NOTARY`. Create that once with `xcrun notarytool store-credentials STATUS_NOTARY`, then run `make build`. That command bumps the build number.

SMC tests, which `make` runs before a build:

```bash
python3 Kit/scripts/run-smc-tests.py
```

## How it is put together

- `Status/` is the app: settings, setup, health, and Shortcuts.
- `Modules/` is CPU, GPU, RAM, Disk, Network, Sensors, Battery, Bluetooth, and Clock.
- `Kit/` is shared widgets, readers, health history, and process sampling.
- `Widgets/` is the macOS widget extension, including Mac Health.
- `SMC/` is the optional privileged helper for fan control.
- `Tests/` holds the unit tests.

There is no config file to edit. Settings live in the app's preferences. History is stored in `~/Library/Application Support/Status/History`.

## Privacy

Status has no account and no analytics. The auto-updater from the upstream app is not in this fork.

When public IP is on (the default), the Network module requests `https://1.1.1.1/cdn-cgi/trace` and the IPv6 equivalent. You can turn that off in Network settings. Latency checks ping a host, `1.1.1.1` unless you change it. Clock can sync with `pool.ntp.org`. That switch is off until you turn it on.

## Uninstall

```bash
sh /Applications/Status.app/Contents/Resources/Scripts/uninstall.sh
```

The script asks for an admin password so it can remove the SMC helper, if you installed one.

## License

[MIT](LICENSE). Status includes code from [Stats](https://github.com/exelban/stats). Both copyright notices are in `LICENSE`.
