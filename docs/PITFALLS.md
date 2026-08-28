# Pitfalls

Every item below cost real downtime on a production system. They are ordered
by how much damage they do.

## 1. Never run fsck on a freshly written slot

**Symptom:** After a seemingly successful update the new slot is empty and
`lost+found` is enormous.

**What happened here:** 59,745 files moved to `lost+found` in one go.

`swupdate` writes a *verified* image. Running `fsck.ext4 -f -y` on it rebuilds
the journal and orphans every inode in the process. Not `-y`, not `-f -y`, and
not even `-n` "just to look" — get in the habit of never pointing fsck at a
slot partition at all.

If a slot really is damaged (`dumpe2fs -h` shows `clean with errors`, usually
because swupdate was interrupted), the fix is to **write the image again**.
swupdate overwrites completely; there is nothing to repair.

fsck belongs to the `/data` partition only — see item 6.

## 2. Boot switching must be the LAST step

Patch `fw_env.config`, `fstab`, init scripts — everything in the target slot
first. Only then touch `cmdline.txt`.

If the script dies halfway through with that ordering, the old, working slot
keeps booting and you have a system to fix things from. With the reverse
ordering the boot pointer is already moved when the failure happens, and the
next reboot lands in a half-patched slot.

**What that looks like:** ping answers, every port is closed — including 22 and
80. It is indistinguishable from a dead Pi, and it is not: `/data` failed to
mount, so dropbear has no host keys and nginx has no config. Only the kernel
and DHCP are up.

## 3. A real SD card hijacks the update

The `mmcblk0 -> sda` symlinks can only be created when no real SD card is
present. Insert one and `/dev/mmcblk0` is a genuine block device again — so
`swupdate` happily flashes **the SD card** while you keep booting the old
firmware from the SSD.

The confusing part: the update reports success. You just never get the new
version.

`check-updates-wrapper.sh` therefore aborts hard when it finds a real card.

## 4. cmdline.txt exists more than once

The kernel takes the **last** `root=` it finds. Sources are:

- `/u-boot/cmdline.txt` on sda1
- `/boot/cmdline.txt` on the SD card, if one is inserted
- the u-boot environment (`fw_printenv` / `fw_setenv`)

Miss one and you get a boot loop or a boot into the wrong slot. Note that
depending on your `config.txt`, u-boot may not be in the picture at all: if it
loads the kernel directly (`kernel=zImage-...`), `root=` comes from
`cmdline.txt` alone and the SD card cannot hijack the boot.

Check what is actually in effect with `cat /proc/cmdline`.

## 5. /u-boot is mounted read-only

```sh
mount -o remount,rw /u-boot
# ... write cmdline.txt ...
mount -o remount,ro /u-boot
```

Without the remount, `open(path, 'w')` fails silently or writes into nothing.
Always read the file back **after** remounting to ro — that is the only check
that proves the write survived.

## 6. /data corruption makes the Pi headless-dead

An unclean shutdown can corrupt the ext4 journal on `/data`. Venus OS then
cannot mount it, and since SSH host keys and all service config live there, you
get the "half boot" from item 2.

You cannot repair it from the running system: runit respawns services holding
the partition, inittab respawns getty shells with their CWD on `/data`, and
overlayfs keeps it busy as an upperdir. `umount` returns EBUSY. Password-SSH
does not help either.

`fsck-data-init.sh` runs as `S02zzz`, before `S03mountall.sh`, and repairs it
automatically. Measured here: check at second 4, "clean" at second 6, full boot
in 30 seconds. It turns a site visit into a non-event.

## 7. A boot script cannot tell you it failed

There is no console, no mail, and probably no credentials on the Pi. Write a
**marker file** on any non-zero exit (`trap ... EXIT`) plus a line to
`/dev/kmsg`, and have your monitoring pick the marker up.

Without it, a failed patch run is silent, and you find out at the next reboot —
which is exactly the worst moment.

## 8. --dry-run must not change state

You reach for `--dry-run` precisely when an update is stuck and you want to know
what would happen. If the dry run deletes the state markers, the diagnosis
destroys the update chain: without `.pending-slot-patch` the patcher never runs
again.

Ours did exactly this until we tested it with the flags actually set. Testing a
dry-run on a clean system proves nothing — set the markers first, then verify
they are still there afterwards.

## 9. truncate(len(s)) is wrong for non-ASCII files

In the Python in-place edit pattern:

```python
with open(path, 'r+') as f:
    f.write(new); f.truncate(len(new))
```

`len()` counts **characters**, `truncate()` expects **bytes**. On a file
containing umlauts or symbols the tail gets cut off — in a shell script that
produces an unbalanced quote and `unexpected EOF while looking for matching "`.

For `cmdline.txt` (100 bytes, pure ASCII) the pattern is fine, which is why it
survives in these scripts. Everywhere else, write the whole file:

```python
io.open(path, 'w', encoding='utf-8').write(new)
```

Then verify with `sh -n` and compare the line count.

## 10. Two writers on one log file interleave

If your script logs with `tee -a "$LOGF"` **and** the caller redirects its
output into the same file, every line is written twice by two independent
append descriptors. They interleave character by character:

```
[[1177::1100::3355]]  SS0022zzzzzz--ffsscckk--ddaattaa  iinnssttaalllliieerrtt
```

Pick one writer. Here `tee` does the logging, so the caller sends stdout to
`/dev/null` and only redirects stderr (to keep Python tracebacks):

```sh
(sleep 15 && sh /data/etc/post-swupdate-patches.sh >/dev/null 2>>/var/log/post-swupdate-patches.log) &
```

Same trap inside the script: a `die()` that pipes through `tee` and *also*
appends `>&2` sends the line back into the very same file. The error message is
then the one line you cannot read — exactly when you need it.

This only shows up when the script runs from the boot hook, never when you call
it by hand, so test it the way it actually runs.

## 11. Do not use sed on fw_env.config

We have seen this file end up containing fstab content after a partial
in-place edit. `fw_printenv` then returns garbage, and a slot decision based on
garbage is an endless reboot cycle. Write the file out in full instead.

## 12. Mount the inactive slot where Venus expects it

Venus OS auto-mounts the inactive slot at `/run/media/sdaX`. Do not invent
`/mnt/newslot` — check with `cat /proc/mounts | grep sda` and use the path that
is actually in use, otherwise you patch one copy and boot another.

## 13. `poweroff` needs a real power cycle

After `poweroff` the Pi does not come back on its own. If you drive the power
through a smart switch, "turn on" is a no-op when it is already on — you need
off, wait, on.

## 14. Overlay QML files break across versions

If you use SetupHelper/PackageManager overlays, a modified QML file can
reference a type that no longer exists after an update. Symptom: the GUI does
not start, `/data/log/gui/current` shows `... is not a type` or
`loading QML files failed`.

Fix the file in `/data/apps/overlay-fs/data/gui/upper/qml/` with Python in-place
(not `sed -i`, which creates a new inode and leaves a stale overlay handle),
then reboot.

## 15. serial-starter re-enables devices you had disabled

If you keep a device off the D-Bus with a udev rule (`ENV{VE_SERVICE}="ignore"`)
and that rule lives in `/data/conf/`, it comes back after an update.

`serial-starter` runs **before** `rcS.local` has copied your rules from `/data`
into `/etc/udev/rules.d/`. It therefore reads the stock rules of the freshly
written slot, which know nothing about your exclusions:

```
18:30:25 INFO: Start service vedirect-interface.ttyUSB1 once
18:30:29 INFO: Start service vedirect-interface.ttyUSB4 once
```

**A `down` file does not protect you** — `svc once` starts the service anyway.
`svstat` then reports the contradictory-looking `up ... , normally down`.

This is not cosmetic. A battery monitor that reappears on the D-Bus also
rejoins the VE.Smart network, and it can push a charge voltage to your solar
chargers: here `/Link/ChargeVoltage` jumped to 56.70 V on both MPPTs while the
absorption voltage configured in the devices was 56.50 V. On a battery whose
BMS cuts off at 3.65 V per cell, 0.2 V at the top of the bank is the difference
between a full charge and a protection event.

Two things to add:

1. `scripts/vedirect-ignore-enforce.sh` — a boot-time enforcer that runs *after*
   the udev rules are in place and shuts down any service on a port carrying
   `VE_SERVICE=ignore`. Hook it into `/data/rcS.local` with a delay; see block
   2b in `rcS.local.example`.

2. A **negative** check in your post-update verification. Ours passed with a
   clean bill of health while the disabled device was back on the bus, because
   it only ever asked whether the expected devices were *present* — never
   whether an unwanted one was *absent*. Assert both.

## 16. `svc -t` will not restart a service that has a `down` file

`svc -t` sends TERM and lets runit restart the process — unless a `down` file
exists in the service directory, in which case it simply stays down. Use
`svc -u` to bring it back up.

Worth knowing before you "just restart" a VE.Direct interface to clear a stale
value: here both solar chargers vanished from the D-Bus for 25 seconds because
`svc -t` stopped them and nothing brought them back.
