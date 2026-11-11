#!/bin/zsh
# Build WiFiFailover.app, install it to ~/Library/Application Support/wifi-failover and (re)load
# the LaunchAgent. Usage: ./install.sh ["<hotspot SSID>"]   |   ./install.sh --uninstall
# Written by Claude.
set -euo pipefail

LABEL=local.wifi-failover
SUPPORT="$HOME/Library/Application Support/wifi-failover"
LOGS="$HOME/Library/Logs/wifi-failover"
APP="$SUPPORT/WiFiFailover.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="${0:A:h}"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  rm -rf "$APP"
  echo "Uninstalled (config and logs kept in $SUPPORT and $LOGS)."
  exit 0
fi

BUILD="$SRC/build/WiFiFailover.app"
rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS"
cp "$SRC/Info.plist" "$BUILD/Contents/Info.plist"
swiftc -O -o "$BUILD/Contents/MacOS/wifi-failover" "$SRC/Sources/main.swift" \
  -framework CoreWLAN -framework CoreLocation -framework AppKit
codesign --force --sign - --identifier "$LABEL" "$BUILD"

mkdir -p "$SUPPORT" "$LOGS" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# Replace the binary in place so the bundle path (and its Location permission entry) stays the same
rm -rf "$APP"
cp -R "$BUILD" "$APP"

if [[ ! -f "$SUPPORT/config.json" ]]; then
  HOTSPOT="${1:-}"   # empty is fine: the agent learns hotspot names from their 172.20.10.x addresses
  cat > "$SUPPORT/config.json" <<EOF
{
  "hotspotSSID": "$HOTSPOT",
  "preferredSSIDs": ["eduroam"],
  "allowAnyKnownNetwork": true,
  "minRSSI": -75,
  "hotspotScanSec": 90,
  "dryRun": false
}
EOF
  echo "Wrote $SUPPORT/config.json (hotspot: $HOTSPOT)"
fi

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/wifi-failover</string>
  </array>
  <!-- long-running watcher: checks every 10 s, scans every 90 s while on the hotspot -->
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>$LOGS/launchd.err</string>
</dict>
</plist>
EOF

# bootout is asynchronous; bootstrapping before the old instance is gone fails with "5: Input/output error"
for _ in {1..20}; do launchctl print "gui/$UID/$LABEL" &>/dev/null || break; sleep 0.5; done
launchctl bootstrap "gui/$UID" "$AGENT"
echo "Installed and started $LABEL. Log: $LOGS/wifi-failover.log"
