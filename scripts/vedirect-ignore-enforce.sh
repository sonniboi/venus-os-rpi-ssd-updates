#!/bin/sh
# Shut down serial services on ports that udev marks as VE_SERVICE=ignore.
#
# Why this exists:
#   You can keep a serial device off the D-Bus with a udev rule:
#
#       SUBSYSTEM=="tty", ENV{ID_VENDOR_ID}=="0403", ENV{ID_MODEL_ID}=="6011", \
#           ENV{ID_USB_INTERFACE_NUM}=="03", ENV{VE_SERVICE}="ignore"
#
#   That rule lives in /data/conf/ so it survives firmware updates -- but on the
#   first boot into a freshly written slot, serial-starter runs BEFORE rcS.local
#   has copied it into /etc/udev/rules.d/. It therefore reads the stock rules of
#   the new slot, which know nothing about the exclusion, and starts the service:
#
#       18:30:29 INFO: Start service vedirect-interface.ttyUSB4 once
#
#   A `down` file in the service directory does NOT prevent this -- `svc once`
#   bypasses it. svstat then reports the contradictory "up ..., normally down".
#
#   This is not cosmetic. A battery monitor that reappears on the bus also
#   rejoins the VE.Smart network and can push a charge voltage to your solar
#   chargers, overriding what you configured in the devices themselves.
#
#   Run this from /data/rcS.local with a delay (block 2b in
#   rcS.local.example), i.e. after udev and serial-starter have settled.
#   It is a no-op on a healthy boot.
#
# See docs/PITFALLS.md item 15.

LOG=/var/log/vedirect-ignore-enforce.log

# ADJUST: service prefixes serial-starter may create for a tty. These are the
# ones shipped with Venus OS; add your own if you run custom serial services.
SERVICE_PREFIXES="vedirect-interface gps-dbus"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

CHANGED=0
for dev in /dev/ttyUSB*; do
    [ -e "$dev" ] || continue
    tty=$(basename "$dev")

    VE=$(udevadm info -q property -n "$dev" 2>/dev/null | sed -n 's/^VE_SERVICE=//p')
    [ "$VE" = "ignore" ] || continue

    for prefix in $SERVICE_PREFIXES; do
        d="/service/$prefix.$tty"
        [ -d "$d" ] || continue
        if svstat "$d" 2>/dev/null | grep -q ': up'; then
            svc -d "$d" 2>>"$LOG"
            log "STOP: $prefix.$tty was running despite VE_SERVICE=ignore -> brought down"
            CHANGED=1
        fi
    done
done

[ "$CHANGED" = "0" ] && log "OK: no ignored port had a running service"
exit 0
