# wipe

Zero-wipe utility for rotational HDD disks (USB-attached).  
Skips SSD, NVMe, USB flash drives, and the live boot disk automatically.

```
  ██╗    ██╗██╗██████╗ ███████╗
  ██║    ██║██║██╔══██╗██╔════╝
  ██║ █╗ ██║██║██████╔╝█████╗
  ██║███╗██║██║██╔═══╝ ██╔══╝
  ╚███╔███╔╝██║██║     ███████╗
   ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝
```

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/launch.sh | sudo bash
```

> Must be run as root.

## What it does

1. Detects and protects all mounted disks (including Ubuntu live USB)
2. Scans all block devices (`/dev/sd*`, `/dev/hd*`)
3. Queues only rotational HDDs (`rotational=1`)
4. Skips SSD, NVMe, USB flash drives
5. Asks for explicit `YES` confirmation (reads from `/dev/tty`, safe with pipe)
6. Prevents system sleep/suspend during wipe (`systemd-inhibit`)
7. Wipes each disk sequentially with `dd if=/dev/zero` at 4M block size
8. Reports status per disk

## Disk selection logic

| Type | Action |
|------|--------|
| Rotational HDD (unmounted) | Wiped |
| SSD / NVMe / USB flash | Skipped |
| Any mounted disk | Skipped (protected) |

## Requirements

- Linux (systemd-based recommended)
- `bash`, `lsblk`, `dd`, `losetup`
- Root privileges

## Warning

**This operation is irreversible.** All data on queued disks will be permanently destroyed.  
Always double-check the disk list before confirming.
