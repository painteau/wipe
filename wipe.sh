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

    [ -b "/dev/$DEV" ] || continue

    if [ "$DEV" = "$LIVE_DISK" ]; then
        SIZE=$(lsblk -dno SIZE /dev/$DEV 2>/dev/null)
        MODEL=$(lsblk -dno MODEL /dev/$DEV 2>/dev/null | xargs)
        echo -e "  ${YELLOW}[~]${NC} /dev/$DEV  ${WHITE}${SIZE}${NC}  ${DIM}${MODEL}${NC}  ${YELLOW}LIVE BOOT - skipped${NC}"
        continue
    fi

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

# --- Confirmation (read from /dev/tty — safe even when piped via curl | bash)
echo -e "  ${RED}${BOLD}WARNING: All data on the above disks will be destroyed.${NC}"
echo ""
echo -ne "  Type ${WHITE}YES${NC} to confirm: "
read CONFIRM </dev/tty
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

    umount /dev/${DEV}* 2>/dev/null

    local DD_LOG
    DD_LOG=$(mktemp)

    # Run dd in background, stderr (stats) to log file
    dd if=/dev/zero of=/dev/$DEV bs=4M conv=fsync 2>"$DD_LOG" &
    local DD_PID=$!

    # Poll progress every 2s via USR1 signal
    while kill -0 "$DD_PID" 2>/dev/null; do
        sleep 2
        kill -USR1 "$DD_PID" 2>/dev/null
        sleep 0.1
        local LINE
        LINE=$(tail -1 "$DD_LOG" 2>/dev/null | tr -d '\r')
        [ -n "$LINE" ] && printf "      \033[2m\033[K%-70s\033[0m\r" "$LINE"
    done

    wait "$DD_PID"
    local EXIT=$?
    printf "\n"

    if [ $EXIT -eq 0 ] || grep -q "No space left" "$DD_LOG"; then
        echo -e "  ${GREEN}[✓]${NC} /dev/$DEV  ${GREEN}DONE${NC}"
    else
        echo -e "  ${RED}[✗]${NC} /dev/$DEV  ${RED}ERROR (exit $EXIT)${NC}"
    fi

    rm -f "$DD_LOG"
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
