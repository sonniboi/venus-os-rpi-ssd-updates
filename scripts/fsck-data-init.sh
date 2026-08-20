#!/bin/sh
### BEGIN INIT INFO
# Provides:          fsck-data
# Required-Start:
# Required-Stop:
# Short-Description: e2fsck the /data partition before it gets mounted (self-healing)
# Default-Start:     S
# Default-Stop:
### END INIT INFO
#
# Why this exists:
#   An unclean shutdown can corrupt the ext4 journal on the /data partition.
#   When that happens, Venus OS cannot mount /data -- and because the SSH host
#   keys, dropbear config and all service configuration live on /data, the Pi
#   comes up in a "half boot": it answers ping, but every port is closed.
#   Headless, that is indistinguishable from a dead device, and the only way
#   out is physical access.
#
#   This script runs as S02zzz, i.e. BEFORE S03mountall.sh, and repairs the
#   partition automatically. It turns a service call into a 30 second boot.
#
#   You cannot fsck /data from the running system: runit respawns services that
#   hold the partition open, inittab respawns getty shells with their CWD on
#   /data, and overlayfs keeps it busy as an upperdir. umount returns EBUSY.
#   Running it before the mount is the only reliable moment.
#
# Install: copy to /etc/rcS.d/S02zzz-fsck-data (chmod +x) in EVERY root slot.
#          post-swupdate-patches.sh does this automatically for new slots.
# Keep the master copy on /data so it survives firmware updates.
#
# Output goes to /dev/kmsg because /var/volatile/tmp is not mounted yet.
# Check afterwards with: dmesg | grep fsck-data

[ "$1" = "start" ] || exit 0

# ADJUST: this must be your /data partition.
DEV=/dev/sda4

[ -b "$DEV" ] || exit 0

# Already mounted? Then we are too late -- do nothing rather than risk damage.
grep -q " /data " /proc/mounts && exit 0

echo "fsck-data: checking $DEV" > /dev/kmsg 2>/dev/null
if e2fsck -p "$DEV" > /dev/kmsg 2>&1; then
    echo "fsck-data: $DEV clean (preen)" > /dev/kmsg 2>/dev/null
else
    # -p (preen) refuses anything that needs a decision. Escalate to -fy.
    echo "fsck-data: preen was not enough -> e2fsck -fy" > /dev/kmsg 2>/dev/null
    e2fsck -fy "$DEV" > /dev/kmsg 2>&1
    echo "fsck-data: e2fsck -fy exit=$?" > /dev/kmsg 2>/dev/null
fi

exit 0
