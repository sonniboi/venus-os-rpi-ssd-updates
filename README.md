# Venus OS firmware updates on a USB/SSD-booted Raspberry Pi

Booting Venus OS from a USB SSD is well documented. What is not documented is
what happens next: **firmware updates stop working**, and the standard advice
becomes "disable automatic updates". You then sit on whatever version you
installed, forever.

This repository fixes that. With these scripts in place, the **normal GUI
update button works** — Settings → Firmware → Online updates — and so does the
nightly auto-update. The Pi writes the image to the correct slot, patches the
new slot, switches over and reboots into it, unattended.

Verified on a Raspberry Pi 4 with a USB SSD, most recently on Venus OS
**Large v3.81** (official release, build 2026-10-05), in both directions on
2026-10-06: updated from v3.80 through the normal update path (the first time the
download was cut twice and resumed on its own, pitfall 23), **rolled back** to v3.80
with the slot patcher in about 40 s (pitfall 24), and updated to v3.81 again in
about four minutes (download included). The GUI overlay type came back on the
upgrades and was repaired by the early-polling fix (pitfall 21); a deliberately
failed download exercised the wrapper's failure path (pitfall 25).

Before that, on **Large v3.80** (official release, build 2026-09-21), installed on 2026-10-02 as a
deliberate **downgrade** from v3.90-beta5 with `-force`: wrapper setup, target slot
unmounted, slot patcher green, back on the new slot (`sda2`) three minutes after the
start, `update-postcheck` green. The first attempt through the GUI button ended in a
boot loop because the wrapper let a downgrade through without its setup — fixed,
see pitfall 22.

Before that, on **Large v3.90-beta4** (build 2026-09-30, candidate feed), updated from
v3.90-beta1 through the GUI button on 2026-10-01: target slot unmounted before
swupdate, write finished after about three minutes, slot patcher green, back on
the new slot (`sda2`) about five minutes after the button was pressed,
`update-postcheck` green, both slots `clean`. The GUI overlay broke again because
SetupHelper rewrites it on every version change — pitfall 21 now covers that and
ships `scripts/gui-overlay-fix.sh`.

Before that, on **Large v3.90-beta1** (build 2026-09-25, candidate feed), updated from the
v3.80 final release through the GUI button on 2026-09-28. This was the first
update with the target-slot unmount of pitfall 20 in place, and the log shows it
doing its job: `vrmlogger` stopped, the slot remounted read-only and fully
unmounted before swupdate started. The download and write took about 80 seconds,
the slot patcher ran less than a minute after the first reboot, the Pi was back on the
new slot about two and a half minutes after the button was pressed, and
`update-postcheck` came back green. This time the freshly written slot came up
`clean`. The jump to a new minor release did break one local GUI customisation,
which has nothing to do with the update mechanism itself — see pitfall 21.

The update before that, to **v3.80** (the final release, build 2026-09-21), from v3.80~53
through the GUI button on 2026-09-22 with the SD card left out: swupdate took
about a minute, the slot patcher ran 50 seconds after the first reboot, and
`update-postcheck` came back green. That update also exposed a new problem: the
freshly written slot came up `clean with errors` although the image was clean,
because the inactive slot is still mounted while swupdate overwrites it. The
files were intact; the wrapper now unmounts the target slot first — see
pitfall 20.

v3.80~50 (2026-09-12) was the first run in which the auto-retry earned its
keep: the first swupdate pass left the target slot unreadable, the slot patcher
refused to touch it, re-ran the update on its own and booted into the freshly
written slot two minutes later — see pitfall 17. v3.80~49 arrived through the
nightly cron on 2026-09-10 and v3.80~46 through the GUI button on 2026-09-05,
both without intervention.

The run before that (v3.80~44 → v3.80~45) was driven by writing the GUI's own
D-Bus path directly (`/Firmware/Online/Install`, see pitfall 18): swupdate
started at 06:14:33 and reported success at 06:15:28, the slot patcher ran at
06:16:15, and the new version came up with all services back a few minutes
later — fully unattended, `update-postcheck` green.

The mechanism has been in use since spring 2026 across multiple firmware
updates. Note that image updates replace `/opt/victronenergy`, so any local
patch there has to be reapplied on every update — see pitfall 19.

## Why updates break

`swupdate` writes the new image to a **hardcoded** `/dev/mmcblk0p2` or
`/dev/mmcblk0p3`. On an SSD-booted Pi those device nodes do not exist — the SSD
is `/dev/sda`.

Worse, if an SD card happens to be inserted, the update is flashed **onto the SD
card** while you keep booting the old firmware from the SSD. The update reports
success; nothing changes.

And even once the image lands in the right place, the new slot still contains a
stock `/etc/fstab`, `/etc/fw_env.config` and boot configuration that all point
at `mmcblk0`. Booting it unmodified gives you a Pi that answers ping with every
port closed.

## How it works

```
GUI "Install update"
  └─> check-updates-wrapper.sh            (installed as check-updates.sh)
        ├── refuses to run if a real SD card is present
        ├── creates /dev/mmcblk0* -> /dev/sda* symlinks
        ├── sets skip-slot-switch + .pending-slot-patch
        ├── snapshots settings.xml
        ├── stops vrmlogger, unmounts the target slot (ro first)
        └─> check-updates.sh.orig -update  (stock Victron script, untouched)
              └─> swupdate writes the image to the inactive slot
                    └─> reboot into the OLD slot (skip flag)

/data/rcS.local sees .pending-slot-patch
  └─> post-swupdate-patches.sh
        ├── fw_env.config, fstab, zzz-resize, boot fsck  (target slot only)
        ├── cmdline.txt on sda1 (+ SD card if present)   ← boot switch, LAST
        └─> reboot into the NEW slot

/data/rcS.local in the new slot
  ├── reinstalls the wrapper (the update replaced check-updates.sh)
  ├── restores udev rules from /data/conf/
  └── runs your post-upgrade fix-ups
```

The key idea: **everything lives under `/data`**, which survives updates, and
`rcS.local` re-establishes it on every boot. Nothing in the root filesystem is
permanently modified except `check-updates.sh`, which is re-wrapped each boot.

The stock Victron script is never edited — it is moved to `.orig` and called
unchanged. Both the GUI and `venus-platform` go through `check-updates.sh`, so
wrapping that one file covers every path that can start an update.

## Contents

| File | Purpose |
|---|---|
| `scripts/check-updates-wrapper.sh` | Makes GUI/auto updates target the SSD. Installed as `check-updates.sh` |
| `scripts/post-swupdate-patches.sh` | Patches the new slot, then switches the boot over |
| `scripts/fsck-data-init.sh` | Boot-time fsck for `/data` — turns a dead Pi into a 30-second boot |
| `scripts/vedirect-ignore-enforce.sh` | Keeps `VE_SERVICE=ignore` devices off the bus after an update (optional) |
| `scripts/gui-overlay-fix.sh` | Repairs a GUI overlay that SetupHelper rewrote with a missing QML type (optional, pitfall 21) |
| `scripts/rcS.local.example` | The hooks that tie it together, with the reasoning inline |
| `docs/PITFALLS.md` | **Read this.** 22 failure modes, each one learned the hard way |

## Requirements

- Raspberry Pi already booting Venus OS from USB/SSD
  ([recipe here](https://community.victronenergy.com/t/recipe-for-booting-venus-os-on-raspi4-from-usb-ssd/48753))
- Two root slots plus a `/data` partition on the SSD (the standard Venus layout)
- The image package `custom-rc.d-early`, which runs `/data/rcS.local`
  — check with `opkg list-installed | grep custom-rc`
- Root shell access

## Installation

```sh
# 1. Copy the scripts to persistent storage
mkdir -p /data/etc
cp scripts/check-updates-wrapper.sh  /data/etc/
cp scripts/post-swupdate-patches.sh  /data/etc/
cp scripts/fsck-data-init.sh         /data/etc/
# only if you exclude serial devices with ENV{VE_SERVICE}="ignore":
cp scripts/vedirect-ignore-enforce.sh /data/etc/
# only if you use SetupHelper together with a GUI overlay (pitfall 21):
cp scripts/gui-overlay-fix.sh        /data/etc/
chmod +x /data/etc/*.sh

# 2. Merge the relevant blocks from scripts/rcS.local.example
#    into your /data/rcS.local (do not blindly overwrite an existing one)

# 3. Install the wrapper once by hand; rcS.local does it on every boot afterwards
CU=/opt/victronenergy/swupdate-scripts/check-updates.sh
cp "$CU" "$CU.orig"
cp /data/etc/check-updates-wrapper.sh "$CU"
chmod +x "$CU"

# 4. Install the boot fsck in the CURRENT slot too
cp /data/etc/fsck-data-init.sh /etc/rcS.d/S02zzz-fsck-data
chmod +x /etc/rcS.d/S02zzz-fsck-data
```

### Verify before you trust it

```sh
# The wrapper must not do anything on a plain check:
/opt/victronenergy/swupdate-scripts/check-updates.sh -check
tail /var/log/check-updates-wrapper.log

# The patcher must be a no-op while no update is pending:
/data/etc/post-swupdate-patches.sh --dry-run

# The boot fsck should show up in the kernel log after a reboot:
dmesg | grep fsck-data
```

Then reboot once and confirm the wrapper is still installed
(`grep check-updates-wrapper /opt/victronenergy/swupdate-scripts/check-updates.sh`).
Only then start a real update.

## Things you must adjust

These scripts encode one specific layout. Check every item against your system:

| Item | Value used here |
|---|---|
| SSD device | `/dev/sda` |
| Boot partition | `sda1`, mounted at `/u-boot` |
| Root slot A / B | `sda2` / `sda3` |
| `/data` partition | `sda4` |
| Slot mapping | `fw_printenv version` → `1` = sda2, `2` = sda3 |
| u-boot env offsets | `0x20000` and `0x24000` in `fw_env.config` |
| Inactive slot mount | `/run/media/sdaX` (Venus auto-mount) |

Confirm yours with `cat /proc/cmdline`, `fw_printenv version`, `lsblk` and
`cat /proc/mounts | grep sda`.

## About automatic updates

The usual advice — "disable automatic updates on SSD boot" — **is correct as
long as your boot path is unfixed**. An unattended update would otherwise write
to the wrong device or leave you in a half-patched slot overnight.

With the wrapper and the patcher in place, automatic updates are safe again,
because every path goes through the same setup. Re-enable them only after you
have completed one manual update successfully and understood the log output.

## Warning

These scripts modify the boot path. A partial or misunderstood installation
gives you a Pi that answers ping with every port closed, and recovery needs
physical access to the machine.

Before your first update: read `docs/PITFALLS.md`, know which slot you are
running from (`cat /proc/cmdline`), and know how to get back
(`fw_setenv version 1|2` plus `cmdline.txt`). Keep a spare SD card with a
plain Venus OS image around as a rescue system — with the SSD unplugged, the Pi
boots from it, and you can then hot-plug the SSD to repair it.

No warranty. This is not endorsed by Victron Energy.

## License

MIT — see [LICENSE](LICENSE).
