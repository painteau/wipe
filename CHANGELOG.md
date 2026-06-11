# Changelog

All notable changes to this project are documented here.

---

## [2.1.0] - 2026-06-11

### Rust TUI station

- **Reboot watchdog**: hold both GPIO buttons for 10 seconds to reboot the Pi
- **Button safety**: long press > 3s without releasing is ignored (reboot gesture, not a wipe trigger), preventing accidental wipe start during reboot
- **Screen blanking**: TTY blanking disabled at startup (`\x1b[9;0]`)
- **Setup script**: one-liner installer for Raspberry Pi (`station/setup.sh`) — system update, deps, binary download + SHA256 verify, systemd service, screen blanking, reboot
- **Full English**: all UI strings, error messages, comments and log output translated to English
- **read_pin_low()**: GPIO pin acquired and released on each read, allowing multiple threads (watchdog + slots) to share pins without rppal ownership conflicts

### Repository

- Reorganized structure: `live/` renamed to `bash/`, `station-rust/` renamed to `station/`
- `launch.sh` kept at repo root (referenced by external scripts)
- All hardcoded GitHub URLs updated after rename
- README fully rewritten in English with complete documentation
- WIPE ASCII logo corrected

---

## [2.0.0] - 2026-06-11

### Rust TUI station (new)

- Complete rewrite of the bash station in Rust using [ratatui](https://github.com/ratatui-org/ratatui)
- Full-screen split display: two independent slots side by side
- Windows 98 defrag-style 10x10 grid of Unicode blocks showing wipe progress
- GPIO button support via `rppal` (no pigpiod required)
- Proactive disk disconnect detection: checks every 200ms, error displayed for 8 seconds minimum
- Self-update on startup: fetches VERSION from GitHub, downloads binary, verifies SHA256, re-executes
- Update blocked if SHA256 file is unavailable (no silent installs)
- GitHub Actions CI: cross-compiles ARM64 binary on every version tag and publishes a GitHub Release

### Slot states

- `WaitingForDisk`: polls for `/dev/sda` or `/dev/sdb`
- `SsdRejected`: non-rotational drives are rejected immediately
- `Ready`: HDD detected, button press required to start
- `Wiping`: write in progress with live speed, ETA, elapsed time
- `Done`: wipe complete, prompts to remove disk
- `Error`: I/O error or disconnect, 8s display before reset

---

## [1.2.0] - 2026-06-11 (bash station security audit)

### Security fixes applied to `bash/station.sh`

- **C1**: SHA256 verification before applying self-update; update blocked if `.sha256` file is unreachable
- **C3**: Device validation — only `/dev/sda` or `/dev/sdb` accepted; any other value exits with error
- **H2**: `lsblk` check before unmount to avoid operating on mounted disks
- **H3**: `mktemp` temp files created with permissions 600; log directory at `/run/wipe-station` with 700
- **H4**: GPIO fallback if `pigpiod` is unavailable; no crash on missing hardware
- **M1**: Log files written with permissions 640
- **M2**: `pigpiod` availability polled before use, no race condition on startup
- **F2**: Version string validated against strict regex before comparison

---

## [1.1.0] - 2026-06-10 (bash station)

- Resilience improvements: dependency check on startup, `pigpiod` watchdog, GPIO fallback if unavailable
- Disk disconnect detection during wipe
- Structured logging with timestamps
- Guards against wiping mounted or loop-backed devices
- `wipestation` dedicated system user (not root)
- USBGuard integration: storage devices allowed, HID/BadUSB blocked
- `udisks2` disabled, udev no-automount rule for USB block devices

---

## [1.0.0] - 2026-06-09 (bash station)

- `bash/station.sh`: split-screen wipe station with hot-swap support
- GPIO button support via `pigpiod`
- Self-update with 7s countdown on startup
- `bash/setup.sh`: Raspberry Pi 4 installer

---

## [0.3.0] - 2026-06-08 (launch.sh)

- `launch.sh` (renamed from `wipe.sh`): one-shot zero-wipe utility for any Linux machine
- Live disk detection via `/proc/mounts` and loop device tracing (protects live USB)
- `dd` progress via `SIGUSR1` + tmpfile (safe with `curl | bash`)
- Read confirmation from `/dev/tty` (safe with piped stdin)
- Case-insensitive `YES` confirmation
- `systemd-inhibit` prevents sleep/suspend during wipe
- SHA256 self-verification before execution