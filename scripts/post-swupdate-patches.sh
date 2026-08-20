#!/bin/sh
# post-swupdate-patches.sh -- patches the freshly written root slot so the Pi
# can actually boot it from USB/SSD.
#
# Runs AFTER swupdate, while still on the OLD slot, and reboots into the new
# one when everything is in place. Triggered from /data/rcS.local when the
# marker /data/.pending-slot-patch exists.
#
# What it patches in / for the target slot:
#   1. fw_env.config       correct /dev/sda offsets (u-boot environment)
#   2. fstab               mmcblk0p -> sda
#   3. zzz-resize-sdcard   disabled (would try to resize a card that isn't there)
#   4. S02zzz-fsck-data    boot-time fsck for /data (see fsck-data-init.sh)
#   5. custom-rc-early.sh  safety net so /data/rcS.local runs in the new slot
#   6. cmdline.txt         on sda1 AND on the SD card, if one is present
#   7. skip flag removed, reboot into the target slot
#
# ORDER MATTERS. Steps 1-5 touch the target slot only; step 6 is what actually
# redirects the boot. If anything fails before step 6, the OLD slot keeps
# booting and you still have a working system. Doing it the other way round
# cost us a recovery session: the boot pointer was already moved when the
# script died, so the next reboot landed in a half-patched slot -- ping
# answered, every port closed.
#
# Flags:
#   --dry-run       show what would happen, change nothing
#   --no-reboot     apply all patches but do not reboot
#   --target sdaN   override the target slot (default: from fw_printenv,
#                   version 1 -> sda2, version 2 -> sda3)
set -eu

# On ANY non-zero exit, leave a persistent marker plus a kernel log line.
# A boot script cannot tell you it failed -- and a silent failure here looks
# exactly like a successful update until the next reboot goes wrong.
# Pick the marker up from your monitoring; it means "update is stuck".
mark_fail() {
  rc=$?
  [ "$rc" = "0" ] && return 0
  echo "post-swupdate-patches: FAILED rc=$rc - slot patch incomplete, boot stays on the old slot" > /dev/kmsg 2>/dev/null || true
  printf '%s rc=%s (log: /var/log/post-swupdate-patches.log)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" > /data/.post-swupdate-failed 2>/dev/null || true
}
trap mark_fail EXIT

DRY=0; NOREBOOT=0; FORCE_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY=1; shift ;;
    --no-reboot) NOREBOOT=1; shift ;;
    --target)    FORCE_TARGET="$2"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | head -n 30; exit 0 ;;
    *) echo "Unknown: $1"; exit 2 ;;
  esac
done

LOGF=/var/log/post-swupdate-patches.log
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" | tee -a "$LOGF"; }
# NOTE: no >&2 here. tee already writes to the log file; sending the same line
# to stderr as well means it arrives a second time via the caller's stderr
# redirect -- two append descriptors on one file interleave character by
# character, and it is the error line that becomes unreadable.
die() { printf '[ERROR] %s\n' "$1" | tee -a "$LOGF"; exit 1; }

log "=== post-swupdate-patches started (dry=$DRY no-reboot=$NOREBOOT target=${FORCE_TARGET:-auto}) ==="

# --- determine target slot -------------------------------------------------
# ADJUST the mapping if your partition layout differs (see README).
if [ -n "$FORCE_TARGET" ]; then
  case "$FORCE_TARGET" in sda2|sda3) TARGET=$FORCE_TARGET ;; *) die "--target must be sda2|sda3" ;; esac
  log "target (forced): $TARGET"
else
  TARGET=$(python3 -c "
import subprocess
fw = subprocess.check_output(['fw_printenv','version'], text=True).strip()
v = fw.split('=')[1]
t = {'1':'sda2','2':'sda3'}.get(v)
if not t: raise SystemExit(f'fw_printenv version={v!r}, expected 1/2')
print(t)")
  log "target (from fw_env): $TARGET"
fi

RUNNING=$(python3 -c "
import re
m = re.search(r'root=/dev/(sda[0-9])', open('/proc/cmdline').read())
print(m.group(1) if m else 'unknown')")
log "running slot: $RUNNING"

# --- special case: target == running slot ---------------------------------
if [ "$TARGET" = "$RUNNING" ]; then
  # Two possible reasons:
  #   a) the wrapper set the flags but no update actually ran -> just clean up
  #   b) the Pi booted straight into the new slot because u-boot read fw_env
  #      before cmdline.txt. Then cmdline.txt still points at the old slot and
  #      MUST be patched -- otherwise the NEXT reboot goes back and breaks.
  CMDLINE_SLOT=$(grep -oE 'root=/dev/sda[0-9]' /u-boot/cmdline.txt | sed 's/.*\///')
  log "target=$TARGET == running=$RUNNING. cmdline.txt points at: $CMDLINE_SLOT"

  if [ "$CMDLINE_SLOT" != "$TARGET" ]; then
    log "cmdline.txt is stale ($CMDLINE_SLOT != $TARGET) -- patching it (no reboot needed, already on target)"
    if [ "$DRY" = "0" ]; then
      TARGET="$TARGET" python3 - <<'PYPATCH'
import subprocess, re, os
target = os.environ['TARGET']
def patch_cmdline(path, label, allow_mmcblk=False):
    c = open(path).read()
    pat = r'root=/dev/(sda[0-9]|mmcblk0p[0-9])' if allow_mmcblk else r'root=/dev/sda[0-9]'
    new = re.sub(pat, f'root=/dev/{target}', c)
    with open(path, 'r+') as f:
        f.write(new); f.truncate(len(new))
    print(f'  [{label}] {new.strip()[:110]}')
# /u-boot is mounted READ-ONLY. Without the remount the write silently fails.
subprocess.run(['mount','-o','remount,rw','/u-boot'], check=True)
try:
    patch_cmdline('/u-boot/cmdline.txt', 'sda1')
finally:
    subprocess.run(['mount','-o','remount,ro','/u-boot'], check=True)
# Only touch the SD cmdline if a REAL SD card is present. On an SSD-only setup
# /dev/mmcblk0p1 is our symlink to sda1, which is already mounted -- mounting
# it a second time yields a read-only mount and an OSError that kills the whole
# script.
if os.path.exists('/dev/mmcblk0p1') and not os.path.islink('/dev/mmcblk0p1'):
    os.makedirs('/tmp/sdboot', exist_ok=True)
    subprocess.run(['mount','/dev/mmcblk0p1','/tmp/sdboot'], check=True)
    try:
        patch_cmdline('/tmp/sdboot/cmdline.txt', 'SD', allow_mmcblk=True)
        subprocess.run(['sync'], check=True)
    finally:
        subprocess.run(['umount','/tmp/sdboot'], check=True)
else:
    print('  [SD] no real SD card - skipped')
PYPATCH
      log "cmdline.txt patches OK (sda1 + SD)"
    fi
  else
    log "cmdline.txt already correct -> flag cleanup only"
  fi

  # A --dry-run must never delete state. You reach for --dry-run exactly when
  # an update is stuck and you want to know what would happen -- deleting
  # .pending-slot-patch there would mean rcS.local never triggers the patcher
  # again, i.e. the diagnosis destroys the update chain.
  if [ "$DRY" = "1" ]; then
    log "DRY-RUN: flags left untouched (would remove: skip-slot-switch, .pending-slot-patch, .post-swupdate-retry, .post-swupdate-failed)"
  else
    log "cleaning up flags..."
    rm -f /data/skip-slot-switch /data/.pending-slot-patch /data/.post-swupdate-retry /data/.post-swupdate-failed
    log "skip-slot-switch + .pending-slot-patch + .post-swupdate-retry + .post-swupdate-failed removed"
  fi
  log "=== end (target == running) ==="
  exit 0
fi

# --- mount the target slot -------------------------------------------------
# Venus OS auto-mounts the inactive slot here. Do NOT invent your own path.
NEWSLOT=/run/media/$TARGET

if ! mountpoint -q "$NEWSLOT" 2>/dev/null; then
  log "mounting /dev/$TARGET -> $NEWSLOT"
  [ "$DRY" = "0" ] && {
    mkdir -p "$NEWSLOT"
    if ! mount /dev/$TARGET "$NEWSLOT" 2>/tmp/mount-err.txt; then
      MOUNT_ERR=$(cat /tmp/mount-err.txt)
      log "mount error: $MOUNT_ERR"
      FS_STATE=$(dumpe2fs -h /dev/$TARGET 2>/dev/null | grep "Filesystem state:" | sed "s/.*state: *//")
      log "filesystem state: ${FS_STATE:-unknown}"
      if echo "$FS_STATE" | grep -q "errors"; then
        # A partially written image ("clean with errors") means swupdate was
        # interrupted. Do NOT fsck it -- see README, that destroys the slot.
        # Just write the image again; swupdate overwrites completely.
        RETRY_FLAG=/data/.post-swupdate-retry
        if [ -f "$RETRY_FLAG" ]; then
          rm -f "$RETRY_FLAG"
          die "/dev/$TARGET still corrupt after auto-retry -- manual inspection needed"
        fi
        log "filesystem errors detected -- auto-retry: re-running the update"
        touch "$RETRY_FLAG"
        nohup /opt/victronenergy/swupdate-scripts/check-updates.sh -update > /tmp/swupdate-retry.log 2>&1 &
        log "update restarted (PID $!) -- Pi reboots after swupdate, then this script runs again"
        exit 0
      fi
      die "mount failed: $MOUNT_ERR"
    fi
  }
else
  log "$NEWSLOT already auto-mounted"
fi

[ -f "$NEWSLOT/opt/victronenergy/version" ] || die "$NEWSLOT does not look like a Venus slot"
rm -f /data/.post-swupdate-retry 2>/dev/null || true
log "target version: $(head -n 1 $NEWSLOT/opt/victronenergy/version) ($(cat $NEWSLOT/etc/venus/image-type 2>/dev/null))"

if [ "$DRY" = "1" ]; then
  log "DRY-RUN: no changes. Would patch: fw_env.config, fstab, zzz-resize, S02zzz-fsck-data, /u-boot/cmdline.txt, SD cmdline.txt"
  log "DRY-RUN: skip flag + reboot skipped"
  log "=== end (dry run) ==="
  exit 0
fi

# --- 1. fw_env.config ------------------------------------------------------
# Written in full rather than sed-patched: we have seen this file end up with
# fstab content after a partial in-place edit, which makes fw_printenv return
# garbage -- and a slot switch based on garbage is a boot loop.
# ADJUST the offsets if your u-boot environment differs.
log "rewriting $NEWSLOT/etc/fw_env.config"
printf '# Configuration file for fw_(printenv/saveenv) utility.\n\n/dev/sda            0x20000         0x4000          0x4000\n/dev/sda            0x24000         0x4000          0x4000\n' > "$NEWSLOT/etc/fw_env.config"

# --- 2. fstab --------------------------------------------------------------
log "patching $NEWSLOT/etc/fstab (mmcblk0p -> sda)"
sed -i 's|/dev/mmcblk0p1|/dev/sda1|g; s|/dev/mmcblk0p4|/dev/sda4|g' "$NEWSLOT/etc/fstab"

# --- 3. zzz-resize-sdcard --------------------------------------------------
if [ -f "$NEWSLOT/etc/init.d/zzz-resize-sdcard" ]; then
  chmod -x "$NEWSLOT/etc/init.d/zzz-resize-sdcard" 2>/dev/null || true
  log "zzz-resize-sdcard disabled"
fi

# --- 4. boot-time fsck for /data ------------------------------------------
if [ -f /data/etc/fsck-data-init.sh ]; then
  cp /data/etc/fsck-data-init.sh "$NEWSLOT/etc/rcS.d/S02zzz-fsck-data"
  chmod +x "$NEWSLOT/etc/rcS.d/S02zzz-fsck-data"
  log "S02zzz-fsck-data installed (boot fsck for /data)"
fi

# --- 5. custom-rc-early hook (safety net) ---------------------------------
# Normally provided by the image package custom-rc.d-early. If it is ever
# missing, /data/rcS.local does not run in the new slot -- no settings restore,
# no wrapper reinstall, no post-upgrade fixes. Cheap to check, expensive to miss.
if [ ! -f "$NEWSLOT/etc/init.d/custom-rc-early.sh" ] && [ -f /data/etc/custom-rc-early.sh ]; then
  cp /data/etc/custom-rc-early.sh "$NEWSLOT/etc/init.d/custom-rc-early.sh"
  chmod +x "$NEWSLOT/etc/init.d/custom-rc-early.sh"
  ln -sf ../init.d/custom-rc-early.sh "$NEWSLOT/etc/rcS.d/S99custom-rc-early.sh"
  log "WARNING: custom-rc-early.sh was missing in the new slot -- restored from /data"
else
  log "custom-rc-early.sh present in the new slot (image package custom-rc.d-early)"
fi

# --- 6. BOOT SWITCH LAST ---------------------------------------------------
# Everything above only touched the target slot. From here on we redirect the
# boot. The kernel takes the LAST root= it finds, so every cmdline source has
# to agree -- a forgotten one is a boot loop.
TARGET="$TARGET" python3 - <<'PYPATCH'
import subprocess, re, os, sys
target = os.environ['TARGET']

def patch_cmdline(path, label, allow_mmcblk=False):
    c = open(path).read()
    pat = r'root=/dev/(sda[0-9]|mmcblk0p[0-9])' if allow_mmcblk else r'root=/dev/sda[0-9]'
    new = re.sub(pat, f'root=/dev/{target}', c)
    # Verify before writing: an empty or malformed root= means kernel panic.
    if not re.search(rf'root=/dev/{target}(\s|$)', new):
        raise SystemExit(f'ERROR {label}: result has no root=/dev/{target}')
    # NOTE: truncate(len(new)) is only safe because cmdline.txt is pure ASCII.
    # For files containing non-ASCII this is a bug -- len() counts characters,
    # truncate() expects bytes, so the tail gets cut off.
    with open(path, 'r+') as f:
        f.write(new); f.truncate(len(new))
    print(f'  [{label}] {new.strip()[:110]}')

# 1. /u-boot/cmdline.txt -- /u-boot is READ-ONLY, remount is mandatory.
subprocess.run(['mount','-o','remount,rw','/u-boot'], check=True)
try:
    patch_cmdline('/u-boot/cmdline.txt', 'sda1')
finally:
    subprocess.run(['mount','-o','remount,ro','/u-boot'], check=True)

# 2. SD card cmdline -- only if a REAL SD card is inserted.
if os.path.exists('/dev/mmcblk0p1') and not os.path.islink('/dev/mmcblk0p1'):
    os.makedirs('/tmp/sdboot', exist_ok=True)
    subprocess.run(['mount','/dev/mmcblk0p1','/tmp/sdboot'], check=True)
    try:
        patch_cmdline('/tmp/sdboot/cmdline.txt', 'SD', allow_mmcblk=True)
        subprocess.run(['sync'], check=True)
    finally:
        subprocess.run(['umount','/tmp/sdboot'], check=True)
else:
    print('  [SD] no real SD card - skipped')

print('python patches OK')
PYPATCH
log "cmdline.txt patches OK"
# Read it back AFTER the remount to ro -- catches a write that went nowhere.
grep -q "root=/dev/$TARGET" /u-boot/cmdline.txt || die "sda1 cmdline.txt not correct after remount ro"

# --- 7. release the skip flag and reboot -----------------------------------
if [ -f /data/skip-slot-switch ]; then
  rm /data/skip-slot-switch
  log "skip flag removed"
fi

sync
log "=== all patches OK ==="

if [ "$NOREBOOT" = "1" ]; then
  log "--no-reboot: not rebooting, run 'reboot' yourself"
  exit 0
fi

# Marker for whatever post-upgrade work you run in the NEW slot (reinstalling
# custom services, udev rules, ...). It has to be set HERE: rcS.local consumed
# the previous marker while running on the old slot.
rm -f /data/.pending-slot-patch /data/.post-swupdate-failed
touch /data/.post-upgrade-pending
log "post-upgrade marker set (fix-up runs in the new slot)"
log "rebooting into $TARGET in 3 s ..."
sleep 3
reboot
