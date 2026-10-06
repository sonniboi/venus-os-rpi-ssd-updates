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
# Run it from /data/rc.local. SetupHelper rewrites the file about 38 s after the first boot of
# a new release and then restarts the GUI (file mtime vs. boot time, four times: 37-38 s). Poll from
# the start and quietly, then keep two late passes as a safety net:
#   [ -x /data/etc/gui-overlay-fix.sh ] && (n=0; while [ $n -lt 48 ]; do \
#     /data/etc/gui-overlay-fix.sh -q; n=$((n+1)); sleep 5; done; \
#     sleep 60; /data/etc/gui-overlay-fix.sh; sleep 360; /data/etc/gui-overlay-fix.sh) &
# Measured on a real upgrade (v3.80 -> v3.81): the first version of this fix (one pass after four
# minutes) left the GUI blank for ~4 min; a 10 s loop starting 25 s after boot fixed it at +63 s
# (blank for ~21 s); the loop above starts at once with 5 s steps (tested separately, not yet timed
# in a real boot).
#
# Option -q: do not log the "OK" lines (for the polling loop). Fixes and errors are always logged.
# Test without touching a device:
#   GUI_OVERLAY_FILE=/tmp/x GUI_OVERLAY_LOG=/tmp/l GUI_OVERLAY_NO_SVC=1 ./gui-overlay-fix.sh

F=${GUI_OVERLAY_FILE:-/data/apps/overlay-fs/data/gui/upper/qml/PageSettings.qml}
LOG=${GUI_OVERLAY_LOG:-/var/log/gui-overlay-fix.log}
QUIET=0; [ "$1" = "-q" ] && QUIET=1
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
logok() { [ "$QUIET" = "1" ] || log "$*"; }

[ -f "$F" ] || { logok "OK: $F missing (no overlay) - nothing to do"; exit 0; }
grep -q "PageSettingsWifiWithAccessPoint {}" "$F" || { logok "OK: overlay without WifiWithAccessPoint"; exit 0; }

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
[ -n "$GUI_OVERLAY_NO_SVC" ] || svc -t /service/gui
log "FIXED: WifiWithAccessPoint replaced, GUI restarted"
# keep only the three newest automatic backups
ls -t "$F".bak-autofix-* 2>/dev/null | sed -n '4,$p' | while read -r x; do rm -f "$x"; done
exit 0
