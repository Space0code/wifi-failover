# wifi-failover

Keeps the Mac online:

- **Wi‑Fi lost → iPhone Personal Hotspot.** macOS Instant Hotspot (System Settings › Wi‑Fi ›
  *Ask to join hotspots* = **Automatic**) does the primary job. It is the only thing that can wake the
  phone's hotspot over Bluetooth. The agent adds a fallback: if you're still offline after 20 s and the
  hotspot is broadcasting, it nudges macOS auto-join (power-cycles Wi‑Fi) so it joins the saved hotspot.
- **On the hotspot → back to known Wi‑Fi.** Every 90 s it scans; if eduroam (preferred) or any other
  saved, non-phone network is in range at ≥ −75 dBm, it power-cycles Wi‑Fi so macOS auto-join
  reconnects with its own stored credentials (incl. 802.1X for eduroam). If that network turns out to
  have no internet within 60 s (e.g. a captive portal), it is skipped for 30 min and the agent
  disconnects from it so macOS falls back to the hotspot.
- **Wi‑Fi without internet for 60 s → hotspot**, but only if the hotspot password is in the keychain
  (see below). Joining a network directly needs its password, and saved ones live in the System
  keychain, which needs admin.

Phone hotspots are recognised by name (`hotspotSSID`) and by their 172.20.10.x address. Names seen with
such an address are remembered in `learned-hotspots.json`.

## Why an app bundle

macOS hides Wi‑Fi network names from CoreWLAN unless the process has Location permission. The agent is
a background `.app` (no Dock icon) so it can hold that permission. **Each rebuild changes the ad-hoc
signature, so macOS asks for Location access again after `./install.sh`. Click Allow.**

## Install / update / remove

```sh
./install.sh "<hotspot SSID>"   # builds, installs to ~/Library/Application Support/wifi-failover, loads LaunchAgent
./install.sh --uninstall
```

LaunchAgent `local.wifi-failover` (KeepAlive). It uses no API tokens or paid services; network traffic
is limited to Apple's captive-portal probe (`captive.apple.com`).

## Status

```sh
tail -f ~/Library/Logs/wifi-failover/wifi-failover.log
cat ~/Library/Application\ Support/wifi-failover/state.json
# what it sees and would pick (run via `open` so it gets the app's Location permission):
open -W -n --stdout /tmp/wf.txt "$HOME/Library/Application Support/wifi-failover/WiFiFailover.app" --args --check; cat /tmp/wf.txt
```

## Config — `~/Library/Application Support/wifi-failover/config.json`

Re-read every 10 s; missing keys use defaults.

| key | default | |
|---|---|---|
| `hotspotSSID` | `""` | your iPhone's hotspot name |
| `preferredSSIDs` | `["eduroam"]` | tried first, in order |
| `allowAnyKnownNetwork` | `true` | `false` = only `preferredSSIDs` |
| `excludeSSIDPatterns` | iphone, galaxy, phone, … | never switched *to* from the hotspot |
| `minRSSI` | `-75` | weaker networks are ignored |
| `hotspotScanSec` | `90` | scan interval while on the hotspot |
| `noInternetFailoverSec` | `60` | Wi‑Fi without internet → hotspot (needs password) |
| `badNetworkCooldownSec` | `1800` | skip a network that failed |
| `dryRun` | `false` | log actions without doing them |

## Optional: hotspot password

Lets the agent join the hotspot directly when the current Wi‑Fi has no internet:

```sh
security add-generic-password -s wifi-failover -a "<hotspot SSID>" -w   # prompts for the password
```

## Notes

- Disconnecting from a network (menu › Disconnect, or `disassociate`) makes macOS pause auto-join for
  it, and power cycles don't clear that. Click the network in the Wi‑Fi menu to re-enable it.
- Turning Wi‑Fi off yourself is respected: the agent does nothing while Wi‑Fi is off.
