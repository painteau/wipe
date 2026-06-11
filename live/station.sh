#!/bin/bash
# station.sh - Wipe station for Raspberry Pi 4
# Split screen, hot-swap, GPIO buttons, auto-update

STATION_URL="https://raw.githubusercontent.com/painteau/wipe/main/live/station.sh"
STATION_BIN="/usr/local/bin/wipe-station.sh"
UPDATE_TIMEOUT=5   # seconds before giving up on network

# GPIO pins (BCM numbering)
GPIO_BTN_SLOT1=17   # Physical pin 11
GPIO_BTN_SLOT2=27   # Physical pin 13

# USB dock slot devices
SLOT1_DEV="/dev/sda"
SLOT2_DEV="/dev/sdb"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# --- Self-update with countdown
self_update() {
    echo ""
    local i=$UPDATE_TIMEOUT
    while [ $i -gt 0 ]; do
        printf "  \033[2mChecking for updates... %ds\033[0m\r" "$i"
        sleep 1
        i=$(( i - 1 ))
    done
    printf "\033[K"

    local tmp
    tmp=$(mktemp)

    # Fetch with hard timeout
    curl -fsSL --max-time "$UPDATE_TIMEOUT" "$STATION_URL" -o "$tmp" 2>/dev/null
    local CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || [ ! -s "$tmp" ]; then
        echo -e "  ${DIM}No network — using local version.${NC}"
        rm -f "$tmp"
        sleep 1
        return
    fi

    local remote_hash local_hash
    remote_hash=$(sha256sum "$tmp" | cut -d' ' -f1)
    local_hash=$(sha256sum "$STATION_BIN" 2>/dev/null | cut -d' ' -f1)

    if [ "$remote_hash" != "$local_hash" ]; then
        echo -e "  ${YELLOW}[~] Update found, applying...${NC}"
        mv "$tmp" "$STATION_BIN"
        chmod +x "$STATION_BIN"
        sleep 1
        exec "$STATION_BIN"
    else
        echo -e "  ${GREEN}[✓] Up to date.${NC}"
        rm -f "$tmp"
        sleep 1
    fi
}

# --- Get disk info
disk_serial() { udevadm info --query=all --name="$1" 2>/dev/null | grep ID_SERIAL= | cut -d= -f2; }
disk_size()   { lsblk -dno SIZE "$1" 2>/dev/null; }
disk_model()  { lsblk -dno MODEL "$1" 2>/dev/null | xargs; }
disk_bytes()  { lsblk -dno SIZE --bytes "$1" 2>/dev/null; }

# --- Estimate wipe time (USB 3.0 ~100 MB/s)
estimate_time() {
    local bytes=$1
    local speed=104857600
    local seconds=$(( bytes / speed ))
    printf "%dh%02dm" $(( seconds / 3600 )) $(( (seconds % 3600) / 60 ))
}

# --- Wait for GPIO button press (Python via pigpio)
wait_button() {
    local pin=$1
    python3 - "$pin" << 'PYEOF'
import sys, pigpio, time
pin = int(sys.argv[1])
pi = pigpio.pi()
pi.set_mode(pin, pigpio.INPUT)
pi.set_pull_up_down(pin, pigpio.PUD_UP)
while True:
    if pi.read(pin) == 0:
        time.sleep(0.05)
        if pi.read(pin) == 0:
            pi.stop()
            sys.exit(0)
    time.sleep(0.05)
PYEOF
}

# --- Wipe a single slot (runs in its own tmux pane)
wipe_slot() {
    local SLOT=$1
    local DEV=$2
    local BTN_PIN=$3

    while true; do
        clear

        echo -e "${CYAN}"
        [ "$SLOT" = "1" ] && echo "  SLOT 1 (LEFT)" || echo "  SLOT 2 (RIGHT)"
        echo -e "${NC}"
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Wait for disk
        if [ ! -b "$DEV" ]; then
            echo -e "  ${DIM}Waiting for disk on $DEV...${NC}"
            while [ ! -b "$DEV" ]; do sleep 1; done
            sleep 1
        fi

        # Check rotational
        DEV_NAME=$(basename "$DEV")
        ROTATIONAL=$(cat "/sys/block/${DEV_NAME}/queue/rotational" 2>/dev/null)
        if [ "$ROTATIONAL" != "1" ]; then
            echo -e "  ${RED}[!] SSD/Flash detected — skipped.${NC}"
            echo -e "  ${DIM}Remove disk to continue.${NC}"
            while [ -b "$DEV" ]; do sleep 1; done
            continue
        fi

        # Display disk info
        local SERIAL MODEL SIZE BYTES ETA
        SERIAL=$(disk_serial "$DEV")
        MODEL=$(disk_model "$DEV")
        SIZE=$(disk_size "$DEV")
        BYTES=$(disk_bytes "$DEV")
        ETA=$(estimate_time "$BYTES")

        echo -e "  ${WHITE}Model  :${NC}  ${MODEL}"
        echo -e "  ${WHITE}Serial :${NC}  ${SERIAL:-unknown}"
        echo -e "  ${WHITE}Size   :${NC}  ${SIZE}"
        echo -e "  ${WHITE}Est.   :${NC}  ~${ETA}"
        echo ""
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}Press button to start wipe...${NC}"
        echo ""

        wait_button "$BTN_PIN"

        echo -e "  ${CYAN}[~] Wiping...${NC}"
        echo ""

        umount ${DEV}* 2>/dev/null

        local DD_LOG
        DD_LOG=$(mktemp)

        dd if=/dev/zero of="$DEV" bs=4M conv=fsync 2>"$DD_LOG" &
        local DD_PID=$!

        while kill -0 "$DD_PID" 2>/dev/null; do
            sleep 2
            kill -USR1 "$DD_PID" 2>/dev/null
            sleep 0.1
            local LINE
            LINE=$(tail -1 "$DD_LOG" 2>/dev/null | tr -d '\r')
            [ -n "$LINE" ] && printf "      \033[2m\033[K%-60s\033[0m\r" "$LINE"
        done

        wait "$DD_PID"
        local EXIT=$?
        printf "\n\n"

        if [ $EXIT -eq 0 ] || grep -q "No space left" "$DD_LOG"; then
            echo -e "  ${GREEN}${BOLD}[✓] DONE — ${SIZE} wiped${NC}"
            echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
        else
            echo -e "  ${RED}${BOLD}[✗] ERROR (exit $EXIT)${NC}"
        fi

        rm -f "$DD_LOG"

        echo ""
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${DIM}Remove disk to wipe another.${NC}"

        while [ -b "$DEV" ]; do sleep 1; done
        sleep 1
    done
}

# --- Main: check if running inside a tmux pane
if [ -n "$WIPE_SLOT" ]; then
    wipe_slot "$WIPE_SLOT" "$WIPE_DEV" "$WIPE_BTN"
    exit 0
fi

# --- Self-update (only on main launch)
self_update

# --- Launch tmux split screen
tmux kill-session -t wipestation 2>/dev/null

tmux new-session -d -s wipestation -x "$(tput cols)" -y "$(tput lines)"
tmux split-window -h -t wipestation

tmux send-keys -t wipestation:0.0 \
    "WIPE_SLOT=1 WIPE_DEV=${SLOT1_DEV} WIPE_BTN=${GPIO_BTN_SLOT1} $STATION_BIN" Enter

tmux send-keys -t wipestation:0.1 \
    "WIPE_SLOT=2 WIPE_DEV=${SLOT2_DEV} WIPE_BTN=${GPIO_BTN_SLOT2} $STATION_BIN" Enter

tmux attach-session -t wipestation
