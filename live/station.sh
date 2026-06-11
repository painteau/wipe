#!/bin/bash
# station.sh - Wipe station for Raspberry Pi 4
# Split screen, hot-swap, GPIO buttons, auto-update

VERSION="1.1.0"

STATION_URL="https://raw.githubusercontent.com/painteau/wipe/main/live/station.sh"
STATION_BIN="/usr/local/bin/wipe-station.sh"
UPDATE_TIMEOUT=7
LOG_FILE="/var/log/wipe-station.log"

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

# --- Logging
log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# --- Dependency check at startup
check_deps() {
    local missing=()
    for cmd in tmux curl dd lsblk udevadm losetup python3; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[!] Missing dependencies: ${missing[*]}${NC}"
        echo -e "${DIM}Run setup.sh first.${NC}"
        log "FATAL missing deps: ${missing[*]}"
        sleep 10
        exit 1
    fi
}

# --- Ensure pigpiod is running
ensure_pigpiod() {
    if ! pgrep -x pigpiod &>/dev/null; then
        log "pigpiod not running, starting..."
        pigpiod 2>/dev/null || true
        sleep 1
    fi
}

# --- Version comparison: returns 0 if $1 > $2
version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]
}

# --- Self-update with countdown
self_update() {
    clear
    echo -e "${CYAN}"
    echo "  ██╗    ██╗██╗██████╗ ███████╗"
    echo "  ██║    ██║██║██╔══██╗██╔════╝"
    echo "  ██║ █╗ ██║██║██████╔╝█████╗  "
    echo "  ██║███╗██║██║██╔═══╝ ██╔══╝  "
    echo "  ╚███╔███╔╝██║██║     ███████╗ "
    echo "   ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝"
    echo -e "${NC}"
    echo -e "  ${DIM}Wipe Station  v${VERSION}${NC}"
    echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local i=$UPDATE_TIMEOUT
    while [ $i -gt 0 ]; do
        printf "  \033[2mChecking for updates... (v%s) %ds\033[0m\r" "$VERSION" "$i"
        sleep 1
        i=$(( i - 1 ))
    done
    printf "\033[K"

    local tmp
    tmp=$(mktemp) || { echo -e "  ${DIM}mktemp failed — skipping update.${NC}"; sleep 1; return; }

    curl -fsSL --max-time "$UPDATE_TIMEOUT" "$STATION_URL" -o "$tmp" 2>/dev/null
    local CURL_EXIT=$?

    if [ $CURL_EXIT -ne 0 ] || [ ! -s "$tmp" ]; then
        echo -e "  ${DIM}No network — running v${VERSION} (local).${NC}"
        rm -f "$tmp"
        sleep 1
        return
    fi

    local remote_version
    remote_version=$(grep '^VERSION=' "$tmp" | head -1 | cut -d'"' -f2)

    if [ -z "$remote_version" ]; then
        echo -e "  ${DIM}Could not parse remote version — running v${VERSION}.${NC}"
        rm -f "$tmp"
        sleep 1
        return
    fi

    if version_gt "$remote_version" "$VERSION"; then
        echo -e "  ${YELLOW}[~] Update: v${VERSION} -> v${remote_version} — applying...${NC}"
        log "Updating v${VERSION} -> v${remote_version}"
        mv "$tmp" "$STATION_BIN" && chmod +x "$STATION_BIN" || {
            echo -e "  ${RED}[!] Update failed — running v${VERSION}.${NC}"
            rm -f "$tmp"
            sleep 1
            return
        }
        sleep 1
        exec "$STATION_BIN"
    else
        echo -e "  ${GREEN}[✓] v${VERSION} — up to date.${NC}"
        rm -f "$tmp"
        sleep 1
    fi
}

# --- Get disk info
disk_serial() { udevadm info --query=all --name="$1" 2>/dev/null | grep ID_SERIAL= | cut -d= -f2; }
disk_size()   { lsblk -dno SIZE "$1" 2>/dev/null; }
disk_model()  { lsblk -dno MODEL "$1" 2>/dev/null | xargs; }
disk_bytes()  { lsblk -dno SIZE --bytes "$1" 2>/dev/null; }

# --- Estimate wipe time, guards against empty/zero
estimate_time() {
    local bytes=$1
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]] || [ "$bytes" -eq 0 ]; then
        echo "unknown"
        return
    fi
    local speed=104857600
    local seconds=$(( bytes / speed ))
    [ "$seconds" -eq 0 ] && { echo "<1m"; return; }
    printf "%dh%02dm" $(( seconds / 3600 )) $(( (seconds % 3600) / 60 ))
}

# --- Wait for GPIO button, fallback to Enter if GPIO unavailable
wait_button() {
    local pin=$1
    ensure_pigpiod

    python3 - "$pin" << 'PYEOF' 2>/dev/null
import sys, pigpio, time
pin = int(sys.argv[1])
try:
    pi = pigpio.pi()
    if not pi.connected:
        sys.exit(1)
    pi.set_mode(pin, pigpio.INPUT)
    pi.set_pull_up_down(pin, pigpio.PUD_UP)
    while True:
        if pi.read(pin) == 0:
            time.sleep(0.05)
            if pi.read(pin) == 0:
                pi.stop()
                sys.exit(0)
        time.sleep(0.05)
except Exception:
    sys.exit(1)
PYEOF

    if [ $? -ne 0 ]; then
        echo -e "  ${DIM}(GPIO unavailable — press Enter to start)${NC}"
        read -r </dev/tty 2>/dev/null || sleep 3
    fi
}

# --- Wipe a single slot (runs in its own tmux pane)
wipe_slot() {
    local SLOT=$1
    local DEV=$2
    local BTN_PIN=$3
    local DD_PID="" DD_LOG=""

    # Cleanup trap for this slot
    trap 'kill "$DD_PID" 2>/dev/null; rm -f "$DD_LOG"' EXIT INT TERM

    while true; do
        DD_PID=""
        DD_LOG=""
        clear

        echo -e "${CYAN}"
        [ "$SLOT" = "1" ] && echo "  SLOT 1 (LEFT)" || echo "  SLOT 2 (RIGHT)"
        echo -e "  ${DIM}v${VERSION}${NC}"
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        # Wait for disk
        if [ ! -b "$DEV" ]; then
            echo -e "  ${DIM}Waiting for disk on $DEV...${NC}"
            while [ ! -b "$DEV" ]; do sleep 1; done
            sleep 1
        fi

        # Check rotational
        local DEV_NAME ROTATIONAL
        DEV_NAME=$(basename "$DEV")
        ROTATIONAL=$(cat "/sys/block/${DEV_NAME}/queue/rotational" 2>/dev/null)
        if [ "$ROTATIONAL" != "1" ]; then
            echo -e "  ${RED}[!] SSD/Flash detected — skipped.${NC}"
            echo -e "  ${DIM}Remove disk to continue.${NC}"
            log "SLOT${SLOT} SSD/Flash on ${DEV} — skipped"
            while [ -b "$DEV" ]; do sleep 1; done
            continue
        fi

        # Disk info
        local SERIAL MODEL SIZE BYTES ETA
        SERIAL=$(disk_serial "$DEV")
        MODEL=$(disk_model "$DEV")
        SIZE=$(disk_size "$DEV")
        BYTES=$(disk_bytes "$DEV")
        ETA=$(estimate_time "$BYTES")

        echo -e "  ${WHITE}Model  :${NC}  ${MODEL:-unknown}"
        echo -e "  ${WHITE}Serial :${NC}  ${SERIAL:-unknown}"
        echo -e "  ${WHITE}Size   :${NC}  ${SIZE:-unknown}"
        echo -e "  ${WHITE}Est.   :${NC}  ~${ETA}"
        echo ""
        echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}Press button to start wipe...${NC}"
        echo ""

        wait_button "$BTN_PIN"

        # Re-check disk still present after button press
        if [ ! -b "$DEV" ]; then
            echo -e "  ${RED}[!] Disk removed before wipe started.${NC}"
            sleep 2
            continue
        fi

        log "SLOT${SLOT} starting wipe: ${MODEL} ${SERIAL} ${SIZE} on ${DEV}"
        echo -e "  ${CYAN}[~] Wiping...${NC}"
        echo ""

        umount ${DEV}* 2>/dev/null || true

        DD_LOG=$(mktemp) || { echo -e "  ${RED}[!] mktemp failed.${NC}"; sleep 3; continue; }

        dd if=/dev/zero of="$DEV" bs=4M conv=fsync 2>"$DD_LOG" &
        DD_PID=$!

        local DISCONNECTED=0
        while kill -0 "$DD_PID" 2>/dev/null; do
            # Detect disk disconnect during wipe
            if [ ! -b "$DEV" ]; then
                kill "$DD_PID" 2>/dev/null
                DISCONNECTED=1
                break
            fi
            sleep 2
            kill -USR1 "$DD_PID" 2>/dev/null
            sleep 0.1
            local LINE
            LINE=$(tail -1 "$DD_LOG" 2>/dev/null | tr -d '\r')
            [ -n "$LINE" ] && printf "      \033[2m\033[K%-60s\033[0m\r" "$LINE"
        done

        wait "$DD_PID" 2>/dev/null
        local EXIT=$?
        printf "\n\n"

        if [ "$DISCONNECTED" -eq 1 ]; then
            echo -e "  ${RED}${BOLD}[!] DISK DISCONNECTED during wipe!${NC}"
            log "SLOT${SLOT} ERROR: disk disconnected during wipe on ${DEV}"
        elif [ $EXIT -eq 0 ] || grep -q "No space left" "$DD_LOG" 2>/dev/null; then
            echo -e "  ${GREEN}${BOLD}[✓] DONE — ${SIZE} wiped${NC}"
            echo -e "  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
            log "SLOT${SLOT} DONE: ${MODEL} ${SERIAL} ${SIZE} on ${DEV}"
        else
            local ERR_MSG
            ERR_MSG=$(tail -1 "$DD_LOG" 2>/dev/null | tr -d '\r')
            echo -e "  ${RED}${BOLD}[✗] ERROR (exit $EXIT)${NC}"
            [ -n "$ERR_MSG" ] && echo -e "  ${DIM}${ERR_MSG}${NC}"
            log "SLOT${SLOT} ERROR exit=${EXIT} msg=${ERR_MSG} on ${DEV}"
        fi

        rm -f "$DD_LOG"
        DD_LOG=""
        DD_PID=""

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

# --- Startup checks
check_deps

# --- Self-update
self_update

# --- Launch tmux split screen
tmux kill-session -t wipestation 2>/dev/null || true

COLS=$(tput cols 2>/dev/null || echo 220)
LINES=$(tput lines 2>/dev/null || echo 50)

tmux new-session -d -s wipestation -x "$COLS" -y "$LINES"
tmux split-window -h -t wipestation

tmux send-keys -t wipestation:0.0 \
    "WIPE_SLOT=1 WIPE_DEV=${SLOT1_DEV} WIPE_BTN=${GPIO_BTN_SLOT1} $STATION_BIN" Enter

tmux send-keys -t wipestation:0.1 \
    "WIPE_SLOT=2 WIPE_DEV=${SLOT2_DEV} WIPE_BTN=${GPIO_BTN_SLOT2} $STATION_BIN" Enter

tmux attach-session -t wipestation
