# wipe

> Zero-wipe utility for rotational HDDs. Two modes: a bash script for quick use and a Rust TUI station designed for a Raspberry Pi kiosk with a 2-bay SATA dock.

```
  ██╗    ██╗██╗██████╗ ███████╗
  ██║    ██║██║██╔══██╗██╔════╝
  ██║ █╗ ██║██║██████╔╝█████╗
  ██║███╗██║██║██╔═══╝ ██╔══╝
  ╚███╔███╔╝██║██║     ███████╗
   ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝
```

**Automatically skips SSDs, NVMe, USB flash drives, and the live boot disk.**

---

## Bash script

For quick, one-shot use on any Linux machine.

```bash
curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/launch.sh | sudo bash
```

Requires root. The script verifies its own SHA256 checksum before running.

### What it does

1. Detects and protects all mounted disks (including the live USB)
2. Scans block devices (`/dev/sd*`, `/dev/hd*`)
3. Queues only rotational HDDs (`rotational=1`)
4. Asks for explicit `YES` confirmation
5. Prevents sleep/suspend during the wipe (`systemd-inhibit`)
6. Wipes each disk sequentially with `dd if=/dev/zero` at 4 MB block size

---

## Rust TUI station

A full-screen terminal interface built with [ratatui](https://github.com/ratatui-org/ratatui), designed to run on a **Raspberry Pi 4** inside a wooden enclosure with a 2-bay SATA dock and physical GPIO buttons. No keyboard required.

### Hardware

| Component | Detail |
|-----------|--------|
| Board | Raspberry Pi 4, ARM64, Ubuntu 24.04 |
| Storage dock | 2-bay USB-SATA (`/dev/sda` + `/dev/sdb`) |
| Button A | GPIO 17 (physical pin 11) |
| Button B | GPIO 27 (physical pin 13) |
| Display | HDMI monitor, no keyboard |

### Interface

```
+--------------------------------------------------------------------+
|  WIPE STATION v2.1.0  |  2026-06-11 14:32:01  |  [hold both 10s = reboot]  |
+--------------------------------+-----------------------------------+
|  SLOT 1                        |  SLOT 2                           |
|                                |                                   |
|  Model  : WD Blue              |  Waiting for a HDD...             |
|  Serial : WD-WX31E46NKSA7      |                                   |
|  Size   : 4000 GB              |                                   |
|  Est.   : ~10h42m              |                                   |
|                                |                                   |
|  ██ ██ ██ ██ ██ ██ ██ ██ ░░ ░░  |                                   |
|  ██ ██ ██ ██ ██ ██ ░░ ░░ ░░ ░░  |                                   |
|  ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░  |                                   |
|  ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░ ░░  |                                   |
|                                |                                   |
|  42.0%  87 MB/s  +18m30s  -25m12s                                 |
+--------------------------------+-----------------------------------+
```

### Slot states

| State | Color | Description |
|-------|-------|-------------|
| Waiting for disk | Gray | No drive detected |
| SSD rejected | Red | Drive is not rotational |
| Ready | Yellow (blinking) | HDD detected, awaiting button press |
| Wiping | Cyan | Write in progress, defrag-style grid |
| Done | Green | Wipe complete, remove the disk |
| Error | Red | I/O error or disk disconnected |

### Button behavior

| Action | Result |
|--------|--------|
| Short press, released (< 3s) | Start wipe on that slot |
| Hold both buttons for 10s | Reboot the Pi |
| Press during active wipe | Ignored |
| Hold > 3s without releasing | Ignored (treated as reboot gesture, not a wipe trigger) |

### Installation

On a fresh Raspberry Pi, run the setup script. It handles everything: system update, dependencies, binary download, SHA256 verification, systemd service, screen blanking, and reboots automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/station-rust/setup.sh | sudo bash
```

What the script does:

1. `apt update && apt upgrade`
2. Installs `curl`, `sudo`, `udev`, `util-linux`
3. Downloads the ARM64 binary and verifies its SHA256
4. Installs it to `/usr/local/bin/wipe-station`
5. Disables screen blanking (`consoleblank=0` in kernel cmdline)
6. Creates and enables the systemd service on `/dev/tty1`
7. Reboots

After reboot, the station starts automatically on boot. Logs: `journalctl -u wipe-station -f`

### Auto-update

On startup, the station fetches `station-rust/VERSION` from GitHub. If a newer version is available, it downloads the binary, verifies the SHA256 checksum, and re-executes itself automatically.

To re-run setup after an OS reinstall or hardware change, just run the one-liner again.

### Build from source

```bash
cd station-rust
cargo build --release --features gpio
```

Cross-compilation to ARM64 is handled by `.github/workflows/release.yml` and triggered automatically on version tags (`v*.*.*`).

---

## Disk selection logic

| Type | Action |
|------|--------|
| Rotational HDD, unmounted | Wiped |
| SSD / NVMe / USB flash | Rejected |
| Any mounted disk | Protected, skipped |

---

> **Warning:** This operation is irreversible. All data on selected disks will be permanently destroyed.
