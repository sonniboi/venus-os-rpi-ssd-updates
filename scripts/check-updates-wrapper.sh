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
#   - unmounts the target slot, which Venus has auto-mounted read-write
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

  # 5. Unmount the target slot (see pitfall 20).
  # Venus auto-mounts the inactive slot read-write at /run/media/sdaX. swupdate
  # then writes the raw image onto that very device while the old filesystem
  # is still mounted on top of it. At the next reboot the old mount is torn
  # down and writes its superblock back -- onto the NEW image. On v3.80 the
  # downloaded image was "clean", yet the freshly written slot was already
  # "clean with errors" at its very first mount: the error state of the old
  # filesystem had been carried over.
  # Remount read-only first (flushes and freezes; a read-only mount writes
  # nothing back), then unmount. If it is still busy, -l is safe because the
  # filesystem is already read-only.
  RUN_SLOT=$(tr ' ' '\n' < /proc/cmdline | sed -n 's|^root=/dev/||p' | head -n 1)
  case "$RUN_SLOT" in
    sda2) TGT_SLOT=sda3 ;;   # ADJUST if your layout differs
    sda3) TGT_SLOT=sda2 ;;
    *)    TGT_SLOT="" ;;
  esac
  if [ -n "$TGT_SLOT" ]; then
    # The usual holder is vrmlogger: when a "storage device" is mounted it
    # keeps its backlog database there (ExternalStorageDir), open for writing.
    # With it running, remount,ro fails with "busy" and only a lazy unmount
    # of a still read-write filesystem is left. Stop it for the update.
    if svstat /service/vrmlogger 2>/dev/null | grep -q ': up'; then
      svc -d /service/vrmlogger && VRM_STOPPED=1 && sleep 2 && log "vrmlogger stopped (was holding the target slot)"
    fi
    for MP in $(awk -v d="/dev/$TGT_SLOT" '$1==d {print $2}' /proc/mounts); do
      mount -o remount,ro "$MP" 2>/dev/null && log "$MP (/dev/$TGT_SLOT) remounted read-only" \
        || log "WARN: remount,ro $MP failed"
      if umount "$MP" 2>/dev/null; then
        log "$MP unmounted"
      else
        log "WARN: $MP busy, held by PID(s): $(fuser -m "$MP" 2>/dev/null)"
        umount -l "$MP" 2>/dev/null && log "$MP lazily unmounted (was busy)" \
          || log "WARN: could not unmount $MP"
      fi
    done
    grep -q "^/dev/$TGT_SLOT " /proc/mounts && log "WARN: /dev/$TGT_SLOT is still mounted" \
      || log "target slot /dev/$TGT_SLOT not mounted -- swupdate writes to a quiet filesystem"
  else
    log "WARN: running slot unknown ($RUN_SLOT) -- target slot not unmounted"
  fi

  log "setup complete -- starting check-updates.sh.orig $*"
fi

if [ "${VRM_STOPPED:-0}" = "1" ]; then
  # A successful update reboots from inside .orig. We only get here when .orig
  # returns without rebooting (download or install failure) -- restart vrmlogger.
  "$ORIG" "$@"
  RC=$?
  svc -u /service/vrmlogger
  log ".orig returned (rc=$RC) -- vrmlogger restarted"
  exit $RC
fi

exec "$ORIG" "$@"
