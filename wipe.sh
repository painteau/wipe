#!/bin/bash
# wipe.sh - Zero-wipe all rotational HDD disks (USB-attached), skip SSD/NVMe/live boot
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/wipe.sh | sudo bash

# --- Colors & styles
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# --- Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Run as root: curl ... | sudo bash${NC}"
    exit 1
fi

# --- Prevent sleep/suspend during wipe
INHIBIT_PID=""
if command -v systemd-inhibit &>/dev/null; then
    systemd-inhibit --what=sleep:idle:handle-suspend-key:handle-lid-switch \
        --who="wipe.sh" --why="Disk wipe in progress" --mode=block \
        sleep infinity &
    INHIBIT_PID=$!
fi
trap '[ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null' EXIT

# --- Header
clear
echo -e "${CYAN}"
echo "  ██╗    ██╗██╗██████╗ ███████╗"
echo "  ██║    ██║██║██╔══██╗██╔════╝"
echo "  ██║ █╗ ██║██║██████╔╝█████╗  "
echo "  ██║███╗██║██║██╔═══╝ ██╔══╝  "
echo "  ╚███╔███╔╝██║██║     ███████╗ "
echo "   ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝"
echo -e "${NC}"
echo -e "${DIM}  Zero-wipe utility  HDD only (rotational disks)${NC}"
echo -e "${DIM}  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# --- Detect live boot disk
LIVE_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE / 2>/dev/null) 2>/dev/null | head -1)
if [ -z "$LIVE_DISK" ]; then
    LIVE_DISK=$(blkid | grep -iE 'LABEL="(Ubuntu|casper|LIVE)"' | sed 's/[0-9]*:.*//' | sed 's|/dev/||' | head -1)
fi
echo -e "  ${DIM}Live boot disk:${NC} ${WHITE}/dev/${LIVE_DISK:-unknown}${NC}  ${DIM}(protected)${NC}"
echo ""

# --- Scan all block devices
TARGETS=()

for SYSPATH in /sys/block/sd* /sys/block/hd*; do
    [ -e "$SYSPATH" ] || continue
    DEV=$(basename "$SYSPATH")

    # Skip if not a block device
    [ -b "/dev/$DEV" ] || continue

    # Skip live boot disk
    if [ "$DEV" = "$LIVE_DISK" ]; then
        SIZE=$(lsblk -dno SIZE /dev/$DEV 2>/dev/null)
        MODEL=$(lsblk -dno MODEL /dev/$DEV 2>/dev/null | xargs)
        echo -e "  ${YELLOW}[~]${NC} /dev/$DEV  ${WHITE}${SIZE}${NC}  ${DIM}${MODEL}${NC}  ${YELLOW}LIVE BOOT - skipped${NC}"
        continue
    fi

    # Check rotational (1 = HDD, 0 = SSD/NVMe/USB flash)
    ROTATIONAL=$(cat "$SYSPATH/queue/rotational" 2>/dev/null)
    SIZE=$(lsblk -dno SIZE /dev/$DEV 2>/dev/null)
    MODEL=$(lsblk -dno MODEL /dev/$DEV 2>/dev/null | xargs)
    TYPE=$(lsblk -dno TRAN /dev/$DEV 2>/dev/null | xargs)

    if [ "$ROTATIONAL" = "1" ]; then
        echo -e "  ${GREEN}[+]${NC} /dev/$DEV  ${WHITE}${SIZE}${NC}  ${DIM}${MODEL}  ${TYPE}${NC}  ${GREEN}HDD - queued${NC}"
        TARGETS+=("$DEV")
    else
        echo -e "  ${RED}[-]${NC} /dev/$DEV  ${WHITE}${SIZE}${NC}  ${DIM}${MODEL}  ${TYPE}${NC}  ${RED}SSD/Flash - skipped${NC}"
    fi
done

echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo -e "  ${RED}[!] No rotational HDD found. Abort.${NC}"
    exit 1
fi

echo -e "  ${BOLD}${WHITE}Disks to wipe:${NC} ${TARGETS[*]}"
echo ""

# --- Confirmation
echo -e "  ${RED}${BOLD}WARNING: All data on the above disks will be destroyed.${NC}"
echo ""
echo -ne "  Type ${WHITE}YES${NC} to confirm: "
read CONFIRM
echo ""

if [ "$CONFIRM" != "YES" ]; then
    echo -e "  ${YELLOW}[~] Aborted.${NC}"
    exit 0
fi

echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# --- Wipe function
wipe_disk() {
    local DEV=$1
    local SIZE=$(lsblk -dno SIZE /dev/$DEV 2>/dev/null)
    local MODEL=$(lsblk -dno MODEL /dev/$DEV 2>/dev/null | xargs)

    echo -e "  ${CYAN}[~]${NC} Wiping ${WHITE}/dev/$DEV${NC}  ${DIM}$SIZE  $MODEL${NC}"
    echo ""

    # Unmount all partitions
    umount /dev/${DEV}* 2>/dev/null

    # dd with progress
    dd if=/dev/zero of=/dev/$DEV bs=4M status=progress conv=fsync 2>&1 \
        | while IFS= read -r line; do
            echo -e "      ${DIM}$line${NC}"
        done

    local EXIT=${PIPESTATUS[0]}
    echo ""

    if [ $EXIT -eq 0 ] || echo "$line" | grep -q "No space left"; then
        echo -e "  ${GREEN}[✓]${NC} /dev/$DEV  ${GREEN}DONE${NC}"
    else
        echo -e "  ${RED}[✗]${NC} /dev/$DEV  ${RED}ERROR (exit $EXIT)${NC}"
    fi

    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# --- Run wipes sequentially
for DEV in "${TARGETS[@]}"; do
    wipe_disk "$DEV"
done

# --- Summary
echo -e "  ${GREEN}${BOLD}All done.${NC}"
echo -e "  ${DIM}Disks wiped: ${TARGETS[*]}${NC}"
echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo ""
