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
But first check whether the files are actually unreadable: a slot can also
carry `clean with errors` as a leftover flag while every file in it is intact
(item 20). Rewriting does no harm there, but it fixes nothing either.

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

## 17. An interrupted swupdate leaves a slot that mounts but cannot be read

Kill an update part-way through — an SSH session that times out is enough — and
the target partition is left holding a partial image. The give-away is not a
mount failure. Venus auto-mounts the inactive slot, so the corrupt slot usually
sits there mounted read-write, and every path inside it returns `EBADMSG`:

```
# ls /run/media/sda2/
ls: /run/media/sda2/etc: Bad message
ls: /run/media/sda2/usr: Bad message
# dumpe2fs -h /dev/sda2 | grep state
Filesystem state:         clean with errors
```

`dumpe2fs` is the reliable test. Do **not** use the D-Bus path
`com.victronenergy.platform /Firmware/Backup/AvailableVersion` for this — it
reports an empty value for a perfectly healthy rollback slot as well, so an
empty value proves nothing. (Measured on a slot that was `clean` and held a
readable image.)

Two consequences worth knowing:

**The patcher fails safe, but it does not repair itself.** `post-swupdate-patches.sh`
dies on the `[ -f "$NEWSLOT/opt/victronenergy/version" ]` check, which is false
because the lookup itself fails. That happens *before* any patching and *before*
the boot switch, so the boot target stays on the healthy slot — the Pi does not
end up half-booted. But `.pending-slot-patch` survives, so every subsequent boot
retries and dies the same way.

**The auto-retry used to be unreachable in exactly this case.** It lived in the
branch that runs when `mount` fails — and the mount had already succeeded. Fixed
by checking the filesystem state at the readability check as well, so a
`clean with errors` slot triggers the retry no matter how it got mounted.

**Field-confirmed on 2026-09-12 (v3.80~49 → v3.80~50).** The first swupdate pass
left the target slot with `Filesystem state: clean with errors`; this time the
mount itself failed (`Structure needs cleaning`), so the original retry branch
fired. The log tells the whole story in six lines:

```
[12:20:37] Mount-Fehler: mount(2) system call failed: Structure needs cleaning.
[12:20:37] Filesystem state: clean with errors
[12:20:37] Auto-Retry: check-updates.sh -update (rewrites /dev/sda3)
[12:22:38] Target-Version: v3.80~50 (large)
[12:22:39] === Alle Patches OK ===
[12:22:39] Reboot in 3 s in sda3 ...
```

The post-update check came back green three minutes later. Nobody touched the
Pi. What corrupted the first pass is not known — the update had been started
from the GUI, not from SSH, and the reboot that followed came only 80 s after
swupdate began, which is shorter than a full write of the large image to this
SSD. Treat a mount failure and an `EBADMSG` mount as the same condition; the
patcher now does.

To clear the state by hand, first confirm `fw_printenv version` still matches the
running slot (1 = sda2, 2 = sda3), then:

```sh
rm -f /data/skip-slot-switch /data/.pending-slot-patch /data/.post-upgrade-pending
umount -l /run/media/sda2      # plain umount says "target is busy"
```

Then start the update again. Never `fsck` the slot — the next full swupdate
overwrites it anyway, and see pitfall 1 for what fsck does to it.

## 18. Do not start an update from an SSH session

`swupdate` downloads a few hundred megabytes and then writes them. If it is a
child of your SSH session, the session dying takes the update with it and you
land in pitfall 17. A shell timeout, a closed laptop or a dropped VPN all count.

The robust way is to let `venus-platform` own the process, which is what the GUI
button does. It is reachable over D-Bus:

```sh
# what the "Press to update" button in Settings -> Firmware -> Online updates does
dbus -y com.victronenergy.platform /Firmware/Online/Install SetValue 1
```

The resulting `check-updates.sh` has `venus-platform` as its parent, so closing
the SSH connection cannot touch it. Useful companions:

| Path on `com.victronenergy.platform` | Meaning |
|---|---|
| `/Firmware/Online/Check` | check for updates, read-only |
| `/Firmware/Online/AvailableVersion` | version offered by the selected feed |
| `/Firmware/Installed/Version` / `/Build` / `/ImageType` | what is running |
| `/Firmware/State`, `/Firmware/Progress` | state and progress |

The feed itself is `com.victronenergy.settings /Settings/System/ReleaseType`
(0 = release, 1 = candidate, 2 = testing, 3 = develop).

If you do drive an update from a script over SSH instead, wrap it in `nohup` and
detach — and never put a client-side `timeout` around the call.

## 19. An image update silently reverts every patch under `/opt`

A firmware update does not merge — it writes a **whole rootfs** into the
inactive slot. Everything you changed under `/opt/victronenergy` is simply not
there afterwards: overlay files, a patched `systemcalc`, a modified driver.
Nothing warns you. The system comes up healthy, and only the behaviour you had
patched in is quietly gone.

This bites hardest when the patch fixed a *display* value rather than a
function. In our case a `systemcalc` patch stops the AC-loads figure from being
clamped; after an update the tile is back to the stock behaviour, which looks
plausible enough that you can miss it for days.

The fix is to treat `/data` as the only durable place and reapply on every
boot. `/data/rc.local` survives updates, so the patch is applied from there:

```sh
# /data/rc.local — reapply after every image update
grep -q 'MY-PATCH-MARKER' /opt/victronenergy/dbus-systemcalc-py/delegates/foo.py \
    || patch -p0 -d / < /data/conf/foo.patch
```

Two rules make this survivable:

1. **Mark your patch** with a unique string, so a boot script can ask "is it
   already applied?" without parsing code.
2. **Verify the count after every update**, not just that the file exists:

```sh
grep -rc 'MY-PATCH-MARKER' /opt/victronenergy/dbus-systemcalc-py/   # expected: 2
```

The same applies to udev rules. A rule you drop in `/etc/udev/rules.d` is gone
after the next update — put it in `/data/conf/` and have `rc.local` install it,
or it will come back to bite you as a device that reappears after months.

## 20. The auto-mounted inactive slot is overwritten while it is mounted

Venus auto-mounts the inactive slot read-write at `/run/media/sdaX` (item 12).
`swupdate` then writes the raw image onto that very partition, underneath the
old filesystem, which is still mounted. Nothing complains. At the next reboot
the old mount is torn down and writes its superblock back — onto the new image.

**What we saw on v3.80 (2026-09-22):** the downloaded `.swu` contained a
`clean` filesystem (`e2fsck -fn` on a copy: no findings). The freshly written
slot reported `mounting fs with errors` at its **very first** mount, before any
of our scripts had touched it, and `dumpe2fs` showed `clean with errors` with no
recorded error event. The old filesystem in that slot had carried the flag since
earlier updates; tearing down its mount stamped it onto the new image. A
checksum comparison of all 53 836 files against the official image found no
differences beyond our own patches — this time it was only the flag.

That it stays harmless is luck, not design. Whatever the old mount still has
buffered goes to disk at that moment. We suspect this also played a part in
the half-written slots of item 17, but that is not proven.

**Who keeps it mounted:** `vrmlogger`. When a "storage device" is mounted it
keeps its backlog database there (`ExternalStorageDir`), open for writing — and
to Venus the auto-mounted slot looks exactly like a USB stick. As a result
`mount -o remount,ro` fails with `mount point is busy`, and a plain `umount`
fails too. `fuser -m /run/media/sdaX` names the process.

**The fix** is in `check-updates-wrapper.sh`, right before swupdate starts:

```sh
svc -d /service/vrmlogger                 # releases the backlog database
mount -o remount,ro /run/media/sda3       # flush and freeze
umount /run/media/sda3                    # now succeeds
```

The read-only remount comes first on purpose. A lazy `umount -l` of a
filesystem that is still read-write only detaches it from the tree; the
superblock stays live and is written back later, which is exactly the problem.
After `remount,ro` there is nothing left to write back, so a lazy unmount would
be harmless as a fallback. If `.orig` returns without rebooting (a failed
download, for example), the wrapper starts `vrmlogger` again.

How to tell that the full unmount really happened: when the slot is mounted
again, the kernel prints a fresh `EXT4-fs (sda3): mounted filesystem`. After a
lazy unmount the still-live superblock is reused without that line.

**If a running slot already carries the flag:** it cannot be cleared on a
mounted root filesystem, and fsck on a slot is off limits anyway (item 1). It
does no harm in operation; the only thing the kernel refuses is online resizing,
which is disabled on these images anyway. The flag disappears the next time that
slot is written, which is two updates later.

**Field-confirmed on 2026-09-28 (v3.80 → v3.90-beta1).** First update with the
fix in place. The wrapper log, in order:

```
[14:33:59] vrmlogger angehalten (hielt den Ziel-Slot offen)
[14:33:59] /run/media/sda3 (/dev/sda3) ro remountet
[14:33:59] /run/media/sda3 ausgehaengt
[14:33:59] Ziel-Slot /dev/sda3 nicht gemountet — swupdate schreibt auf ein ruhendes Dateisystem
[14:35:19] .orig beendet (rc=0) — vrmlogger wieder gestartet
```

(`vrmlogger` stopped, slot remounted read-only, unmounted, swupdate writes to a
filesystem nobody holds, `vrmlogger` restarted.) The freshly written `sda3`
reported `Filesystem state: clean`, and the slot that had carried the flag
(`sda2`, now the rollback slot) reads `clean` as well.

## 21. A GUI overlay can reference a QML type the new release no longer has

This one is not caused by the SSD boot, but it shows up during exactly the kind
of update this repository makes routine, so it belongs here.

If you customise the classic GUI through an overlay (for example
`/data/apps/overlay-fs/data/gui/upper/qml/PageSettings.qml`), your copy of the
file is frozen at the release you took it from. The overlay survives the image
update — which is the point — but it keeps referencing components by name. When
a later release removes or renames one of them, the GUI no longer loads:

```
PageSettings.qml:121:32: PageSettingsWifiWithAccessPoint is not a type
loading QML files failed
```

We hit this on the jump to v3.90-beta1: the overlay, taken from an earlier
build, still instantiated `PageSettingsWifiWithAccessPoint`, which the new
image does not ship. Everything else on the device kept running; only the local
GUI (and its VNC view) was dead.

**Fix:** replace the missing type in the overlay file and restart the GUI
service — no reboot needed:

```sh
F=/data/apps/overlay-fs/data/gui/upper/qml/PageSettings.qml
cp "$F" "$F.bak"
python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
b = open(p, 'rb').read()
n = b.replace(b'PageSettingsWifiWithAccessPoint {}', b'PageSettingsWifi {}')
with open(p, 'r+b') as f:        # in place: overlayfs keeps the same inode
    f.write(n); f.truncate(len(n))
PY
svc -t /service/gui
```

Two details matter. Write the file **in place** rather than with `sed -i`:
`sed -i` creates a new inode, and the merged overlay view can keep serving the
old one until the next remount. And work on **bytes**: `truncate(len(text))`
on a decoded string cuts off the end of any file that contains non-ASCII
characters, because `len()` counts characters, not bytes.

**Prevention:** after every update, check the GUI log for this pattern before
you walk away:

```sh
tail -n 30 /data/log/gui/current | grep -iE 'is not a type|loading qml files failed'
```

**It comes back on every update if SetupHelper is installed.** On the next
update (v3.90-beta1 -> v3.90-beta4, 2026-10-01) the same error was back,
although the overlay had been fixed. The file's modification time was the
first boot of the new slot: SetupHelper (v9.3) reinstalls its patches after
every version change and, in doing so, rewrites the overlay `PageSettings.qml`
from the image original — which on the Pi contains the missing type. A one-off
fix therefore only lasts until the next release.

`scripts/gui-overlay-fix.sh` makes it stick: it applies the byte-exact fix above
only when the type is present, restarts the GUI and logs to
`/var/log/gui-overlay-fix.log`. Verified on the device by restoring the broken
file and running the script: patched 4362 -> 4347 bytes,
`loading QML files succeeded`.

**Timing (v3.80 -> v3.81, 2026-10-06, the fourth occurrence):** the first
version of this fix ran four minutes after boot, so the GUI stayed blank for
about four minutes on every update. The timestamps of the backup copies the
script keeps show when SetupHelper really rewrites the file: 37 s after boot
(file written 19:40:49, boot 19:40:12), and about the same on the two earlier
updates. Now poll early and quietly instead (`gui-overlay-fix.sh -q`, which logs
only fixes and errors), plus two late passes as a safety net. The example call
is in the script header.

**Field result (v3.80 -> v3.81 again, 2026-10-06, 20:35 boot):** SetupHelper
rewrote the file at +38 s and the GUI came back up broken at +42 s. The
10 s loop that started 25 s after boot fixed it at +63 s, so the GUI was blank
for about 21 s instead of four minutes. The loop in the script header starts at
once and steps every 5 s, which should shrink that to a few seconds; that
version has been tested on its own but not yet timed in a real boot. The
rewrite only happens on an **upgrade**: after a rollback (v3.81 -> v3.80) the
file was left alone and the GUI loaded at once.

## 22. A downgrade through the GUI button writes an unpatched slot

**Symptom:** After pressing *Install* to go back to an older release, the Pi
reboots every ~40 seconds. It answers ping for a few seconds per cycle, SSH
for even less, and it keeps booting the *old* slot.

**What happened here (2026-10-02, v3.90-beta5 -> v3.80):** the GUI button calls
`check-updates.sh -update` **without** `-force`. The wrapper's pre-check saw
`available < installed`, decided "no upgrade" and skipped the USB/SSD setup —
but still handed the call to the stock script. **The stock script installs on
`-update` even when the version is older.** So v3.80 was written to the
inactive slot without the slot patcher, and U-Boot's `version` was switched to
it. A local boot hook then saw "U-Boot wants sda2, cmdline says sda3", tried to
rewrite `cmdline.txt` on a partition that is mounted read-only, ignored the
failed `sed`, logged "updated" and rebooted — about two hours of boot loop.
A watchdog test script with `sleep 30` against `test-timeout = 10` caused
additional reboots during early boot.

**Fix (in `scripts/check-updates-wrapper.sh`):**

- a manual `-update` to a *different* version, older or newer, gets the full
  setup, exactly like an upgrade;
- an `-update` that would run without the setup is **aborted** (exit 1) and
  never reaches the stock script.

**Lessons for any boot hook you write yourself:**

- Never reboot after a step whose success you did not verify. Check the file
  after writing it (`grep -q "root=$TARGET " cmdline.txt`).
- Better still, do not let a boot hook switch slots at all. A slot that was not
  prepared by the patcher has the wrong `fstab`/`fw_env.config` and would not
  come up properly anyway. Report the mismatch and leave the decision to a human.
- A watchdog `test-binary` must finish well inside `test-timeout`. Use a grace
  period after boot and "failed twice in a row" instead of `sleep`.

**Getting out of the loop:** the boot window is short (ping from ~20 s, SSH from
~23 s, reboot at ~28 s). A loop on another host that retries SSH every second
and runs `touch /data/skip-slot-switch` as soon as it gets in is enough; the
next boot stays on the running slot. Then redo the downgrade properly with
`-force` (wrapper setup, patcher, switch). Verified on the device the same day:
v3.80 written, patched and booted cleanly, `update-postcheck` green.

## 23. A download can stall for minutes and still succeed

`swupdate` fetches the image over HTTPS. On the v3.81 update (2026-10-06) the
connection to the update server was dropped twice, at 76 MB and again at
168 MB of 322 MB. The log then shows

```
[download_from_url] : Connection with server interrupted, try RESUME after 76365195
```

and nothing else for up to about five minutes, before the transfer continues
with a range request from that offset and finishes. DNS, the server and range
requests were fine the whole time (a `HEAD` on the image URL returned 200 and a
ranged `GET` returned 206), and the cause of the drops was not found. The
command line the stock script builds is `swupdate ... -t 30 -r 3` (30 s timeout,
three retries), so a third drop could fail the run — it did not.

**What to do:** nothing. Do not kill `swupdate` and do not restart the update
from another session: an interrupted write leaves a half-written target slot
and live markers (see pitfall 17 and pitfall 18). Judge by facts rather than by
silence: the update is stuck only if `swupdate` has been gone for minutes while
`fw_printenv version` has not changed, or if nothing has changed for more than
about ten minutes. While waiting, the read-only checks are safe: the last
`swupdate` log line, `ps | grep swupdate`, and whether the markers are still
set.

**Watching it:** `tai64nlocal < /var/log/swupdate/current | tail` shows
`Received : <bytes> / <total>` once a second while data flows. After a RESUME
the denominator is the remaining size, not the full size (here 246250725 =
322615920 - 76365195).

## 24. A rollback must set the boot environment itself

Moving back to the other slot is cheap when the old image is still on the SSD
and was patched when it was installed: patch `cmdline.txt` for that slot and
reboot. What `post-swupdate-patches.sh` did **not** do until 2026-10-06 is touch
the boot environment (`fw_printenv version`). In an update that is
`swupdate`'s job, and the script even derives its target from the value
`swupdate` just wrote. In a rollback (`--target`, i.e. a target that differs
from the slot the environment names) nobody flips it. The system would boot the
older slot with the environment still naming the slot it had just left. The
next `swupdate` picks "the other slot" from that value and would write into the
slot that is **running**.

The script now aligns the environment itself when `--target` differs from it
(`fw_setenv version 1|2`, read back, abort on failure; the dry run says "would
align the boot env (version=2 -> 1)"). Normal updates are untouched. Verified
by a real rollback v3.81 -> v3.80 on 2026-10-06: the environment already read
`version=1` before the reboot, the Pi was back on the older slot after about
37 s, the post-update check was green, and the following upgrade wrote the
other slot as expected.

Do the rollback with the patcher, not by hand:

```sh
/data/etc/post-swupdate-patches.sh --dry-run --target sda2   # read the plan first
nohup /data/etc/post-swupdate-patches.sh --target sda2 > /tmp/rollback.log 2>&1 &
```

Before you do, check that the slot you roll back to is itself patched for the
SSD (`fstab` without `mmcblk`, `fw_env.config` pointing at `/dev/sda`, the
resize script not executable); a slot that was installed and patched through
this chain is.

## 25. The stock update script returns 0 after a failed download

`check-updates.sh` ran `swupdate`, which stopped with `do_swupdate stopped with
exitcode 1` because the download target was unreachable — and the script
returned **0**. A wrapper that decides by the exit code would call that a
success. Decide by the boot environment instead: `swupdate` flips `version`
when it has written a slot, so an unchanged value after the script returns means
nothing was switched. The wrapper in this repository does exactly that, clears
the two armed markers and calls an optional `/data/etc/update-failed-hook.sh`
(a place for a notification). Tested on the device by pointing the update at a
port that refuses connections: `check-updates.sh -swu http://127.0.0.1:9/x.swu`
writes no image, `swupdate` retries for about half a minute, then the failure
path runs (markers removed, `vrmlogger` back up, boot environment unchanged).

One side effect to know: such a test leaves the test URL in the platform's
"available build" state until the next check. `check-updates.sh -check`
refreshes it.

