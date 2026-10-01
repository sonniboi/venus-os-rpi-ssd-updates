#!/bin/sh
# gui-overlay-fix.sh -- keeps the classic GUI loading after Venus OS updates (pitfall 21).
#
# SetupHelper (seen with v9.3) reinstalls its patches after every version change and,
# while doing so, rewrites the overlay copy of PageSettings.qml from the image original.
# On the Raspberry Pi that file instantiates "PageSettingsWifiWithAccessPoint {}", a type
# the image does not ship -> "is not a type", "loading QML files failed", blank GUI.
# This script replaces the type byte-exactly with "PageSettingsWifi {}" and restarts the
# GUI. Idempotent: does nothing when the type is not present.
#
# Run it from /data/rc.local a few minutes after boot, e.g.
#   [ -x /data/etc/gui-overlay-fix.sh ] && (sleep 240; /data/etc/gui-overlay-fix.sh; sleep 360; /data/etc/gui-overlay-fix.sh) &
# (SetupHelper takes a variable amount of time after boot, hence two passes.)

F=/data/apps/overlay-fs/data/gui/upper/qml/PageSettings.qml
LOG=/var/log/gui-overlay-fix.log
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

[ -f "$F" ] || { log "OK: $F missing (no overlay) - nothing to do"; exit 0; }
grep -q "PageSettingsWifiWithAccessPoint {}" "$F" || { log "OK: overlay without WifiWithAccessPoint"; exit 0; }

cp -a "$F" "$F.bak-autofix-$(date +%Y%m%d-%H%M%S)"
python3 - "$F" <<'PY' >> "$LOG" 2>&1
import sys
p = sys.argv[1]
b = open(p, 'rb').read()
n = b.replace(b'PageSettingsWifiWithAccessPoint {}', b'PageSettingsWifi {}')
# r+ instead of a new file: overlayfs keeps serving the old inode until the next remount
f = open(p, 'r+b'); f.write(n); f.truncate(len(n)); f.close()
print('patched: %d -> %d bytes' % (len(b), len(n)))
PY
if grep -q "PageSettingsWifiWithAccessPoint {}" "$F"; then
  log "ERROR: patch did not apply"; exit 1
fi
svc -t /service/gui
log "FIXED: WifiWithAccessPoint replaced, GUI restarted"
# keep only the three newest automatic backups
ls -t "$F".bak-autofix-* 2>/dev/null | sed -n '4,$p' | while read -r x; do rm -f "$x"; done
exit 0
