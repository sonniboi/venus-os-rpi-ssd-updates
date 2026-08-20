#!/bin/sh
# check-updates-wrapper.sh -- makes Venus OS GUI firmware updates work on USB/SSD boot.
#
# Installed as /opt/victronenergy/swupdate-scripts/check-updates.sh, with the
# original moved aside to check-updates.sh.orig. Both the GUI button and the
# nightly auto-update cron go through this file, so a single wrapper covers
# every path that can start an update.
#
# The problem it solves:
#   swupdate writes the new image to a HARDCODED /dev/mmcblk0p2 or p3. On an
#   SSD-booted Pi those nodes do not exist (the SSD is /dev/sda), so the update
#   either fails or -- much worse, if an SD card happens to be inserted -- gets
#   flashed onto the SD card while you keep running from the SSD.
#
# What it does before handing over to the original script:
#   - refuses to run if a REAL SD card is present (see SD guard below)
#   - creates /dev/mmcblk0* -> /dev/sda* symlinks so swupdate hits the SSD
#   - sets /data/skip-slot-switch so the Pi reboots into the OLD slot first
#   - sets /data/.pending-slot-patch so rcS.local runs post-swupdate-patches.sh
#   - snapshots settings.xml
#
# When setup is needed:
#   -check                        -> no setup (version query only)
#   -auto + AutoUpdate=0          -> no setup (the original does nothing anyway)
#   -auto + AutoUpdate=1/2        -> setup (a real update may follow)
#   -update | -swu | (no args)    -> setup (real update)
#
# A false-positive setup (e.g. -update with no newer version) is harmless:
# post-swupdate-patches.sh detects Target==Running on the next boot and cleans
# the flags up again.

ORIG=/opt/victronenergy/swupdate-scripts/check-updates.sh.orig
LOGF=/var/log/check-updates-wrapper.log
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" | tee -a "$LOGF"; }

if [ ! -f "$ORIG" ]; then
  log "FATAL: check-updates.sh.orig missing -- wrapper not installed correctly"
  exit 1
fi

# --- parse arguments -------------------------------------------------------
IS_CHECK=0
IS_AUTO=0
IS_UPDATE=0
HAS_FORCE=0
HAS_SWU=0
for arg in "$@"; do
  case "$arg" in
    -check)  IS_CHECK=1  ;;
    -auto)   IS_AUTO=1   ;;
    -update) IS_UPDATE=1 ;;
    -force)  HAS_FORCE=1 ;;
    -swu)    HAS_SWU=1   ;;
  esac
done

# --- decide whether setup is needed ---------------------------------------
SETUP=1
[ "$IS_CHECK" = "1" ] && SETUP=0

if [ "$IS_AUTO" = "1" ] && [ "$SETUP" = "1" ]; then
  AUTO_SETTING=$(dbus -y com.victronenergy.settings /Settings/System/AutoUpdate GetValue 2>/dev/null || echo "")
  if [ "$AUTO_SETTING" = "0" ]; then
    SETUP=0
    log "auto mode + AutoUpdate=0 -> no setup needed"
  fi
fi

# Pre-check for -auto/-update without -force/-swu: only set up when a newer
# version really exists. Without this, every nightly auto-check would leave
# stale flags behind, and a stale skip-slot-switch is a boot-loop waiting to
# happen.
if [ "$SETUP" = "1" ] && [ "$HAS_FORCE" = "0" ] && [ "$HAS_SWU" = "0" ] && ([ "$IS_AUTO" = "1" ] || [ "$IS_UPDATE" = "1" ]); then
  CHECK_OUT=$("$ORIG" -check 2>&1)
  INSTALLED=$(echo "$CHECK_OUT" | awk '/^installed:/ {print $2}')
  AVAILABLE=$(echo "$CHECK_OUT" | awk '/^available:/ {print $2}')
  # Only treat it as an upgrade when available is numerically NEWER than
  # installed (build timestamps, YYYYMMDDHHMMSS). This also protects against
  # downgrade feeds (e.g. switching from candidate back to release).
  # -force bypasses this check.
  UPGRADE=0
  if [ -n "$INSTALLED" ] && [ -n "$AVAILABLE" ]; then
    if [ "$AVAILABLE" -gt "$INSTALLED" ] 2>/dev/null; then UPGRADE=1; fi
  fi
  if [ "$UPGRADE" = "1" ]; then
    log "pre-check: upgrade available (installed=$INSTALLED < available=$AVAILABLE) -> setup"
  else
    SETUP=0
    log "pre-check: no upgrade (installed=$INSTALLED, available=$AVAILABLE) -> no setup"
  fi
fi

# --- setup for a real update ----------------------------------------------
if [ "$SETUP" = "1" ]; then
  log "=== update setup for USB/SSD (args: $*) ==="

  # 0. SD CARD GUARD.
  # With a real SD card inserted, /dev/mmcblk0 is a genuine block device and
  # our symlinks below cannot be created -- swupdate would then flash the SD
  # card instead of the SSD. You would keep booting the old firmware from the
  # SSD and wonder why the update "did nothing". Abort hard instead.
  if [ -b /dev/mmcblk0 ] && [ ! -L /dev/mmcblk0 ]; then
    log "ABORT: real SD card detected (/dev/mmcblk0) - swupdate would flash the SD card instead of the SSD! Remove the SD card, then retry."
    exit 1
  fi

  # 1. Skip flag: makes the Pi reboot into the OLD (still working) slot after
  # swupdate. Without it the Pi tries to boot a slot whose cmdline.txt, fstab
  # and fw_env.config have not been patched yet -> boot loop, no network.
  touch /data/skip-slot-switch
  log "skip-slot-switch set"

  # 2. Marker that makes rcS.local run post-swupdate-patches.sh after reboot.
  touch /data/.pending-slot-patch
  log ".pending-slot-patch marker set"

  # 3. Snapshot settings.xml (device instances, VRM IDs, display settings).
  cp /data/conf/settings.xml /data/conf/settings.xml.pre-update 2>/dev/null || true
  log "settings.xml.pre-update saved"

  # 4. mmcblk0 -> sda symlinks, so swupdate writes to the SSD.
  # ADJUST if your layout differs (see README).
  if [ -b /dev/sda ] && [ -b /dev/mmcblk0 ] && [ ! -L /dev/mmcblk0 ]; then
    rm -f /dev/mmcblk0 /dev/mmcblk0p1 /dev/mmcblk0p2 /dev/mmcblk0p3 /dev/mmcblk0p4
    ln -sf /dev/sda  /dev/mmcblk0
    ln -sf /dev/sda1 /dev/mmcblk0p1
    ln -sf /dev/sda2 /dev/mmcblk0p2
    ln -sf /dev/sda3 /dev/mmcblk0p3
    ln -sf /dev/sda4 /dev/mmcblk0p4
    log "mmcblk0 -> sda symlinks created"
  else
    log "mmcblk0 already a symlink -- skipped symlink setup (flags are set)"
  fi

  log "setup complete -- starting check-updates.sh.orig $*"
fi

exec "$ORIG" "$@"
