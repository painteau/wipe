#!/bin/bash
# launch.sh - Zero-wipe all rotational HDD disks (USB-attached), skip SSD/NVMe/live boot
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/launch.sh | sudo bash

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
        --who="launch.sh" --why="Disk wipe in progress" --mode=block \
        sleep infinity &
    INHIBIT_PID=$!
fi
trap '[ -n "$INHIBIT_PID" ] && kill "$INHIBIT_PID" 2>/dev/null' EXIT

# --- Detect protected disks
# A disk is protected if any of its partitions is mounted,
# OR if a loop device backed by a file on it is mounted (Ubuntu live squashfs).
is_protected() {
    local disk=$1

    # Direct mount: /dev/sda1, /dev/sda2, etc. in /proc/mounts
    if grep -q "^/dev/${disk}" /proc/mounts 2>/dev/null; then
        return 0
    fi

    # Loop device tracing: squashfs on USB stick (Ubuntu live)
    while IFS= read -r loop; do
        local backing
        backing=$(losetup -n -O BACK-FILE "$loop" 2>/dev/null)
        [ -z "$backing" ] && continue
        local src
        src=$(df -P "$backing" 2>/dev/null | awk 'NR==2{print $1}')
        [ -z "$src" ] && continue
        local parent
        parent=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
        [ "$parent" = "$disk" ] && return 0
    done < <(losetup -l -n -O NAME 2>/dev/null)

    return 1
}

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

# --- Scan all block devices
TARGETS=()

for SYSPATH in /sys/block/sd* /sys/block/hd*; do
    [ -e "$SYSPATH" ] || continue
    DEV=$(basename "$SYSPATH")

    [ -b "/dev/$DEV" ] || continue

    SIZE=$(lsblk -dno SIZE /dev/$DEV 2>/dev/null)
    MODEL=$(lsblk -dno MODEL /dev/$DEV 2>/dev/null | xargs)
    ROTATIONAL=$(cat "$SYSPATH/queue/rotational" 2>/dev/null)
    TYPE=$(lsblk -dno TRAN /dev/$DEV 2>/dev/null | xargs)

    if is_protected "$DEV"; then
        echo -e "  ${YELLOW}[~]${NC} /dev/$DEV  ${WHITE}${SIZE}${NC}  ${DIM}${MODEL}${NC}  ${YELLOW}MOUNTED - skipped${NC}"
        continue
    fi

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

    dd if=/dev/zero of=/dev/$DEV bs=4M conv=fsync 2>"$DD_LOG" &
    local DD_PID=$!

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
