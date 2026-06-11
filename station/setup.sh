#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# WIPE STATION - Raspberry Pi setup
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/station/setup.sh | sudo bash
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step() { echo -e "\n${CYAN}${BOLD}[$1/$STEPS] $2${NC}"; }
ok()   { echo -e "${GREEN}  OK${NC} $1"; }
die()  { echo -e "${RED}  ERROR: $1${NC}"; exit 1; }

STEPS=7

[[ $EUID -ne 0 ]] && die "Run as root: sudo bash setup.sh"

echo -e "${BOLD}"
cat << 'EOF'
  ██╗    ██╗██╗██████╗ ███████╗
  ██║    ██║██║██╔══██╗██╔════╝
  ██║ █╗ ██║██║██████╔╝█████╗
  ██║███╗██║██║██╔═══╝ ██╔══╝
  ╚███╔███╔╝██║██║     ███████╗
   ╚══╝╚══╝ ╚═╝╚═╝     ╚══════╝

  Station Setup — Raspberry Pi
EOF
echo -e "${NC}"

# -----------------------------------------------------------------------------
step 1 "System update"
apt-get update -qq
apt-get upgrade -y -qq
ok "System up to date"

# -----------------------------------------------------------------------------
step 2 "Dependencies"
apt-get install -y -qq \
    curl \
    sudo \
    udev \
    util-linux
ok "Dependencies installed"

# -----------------------------------------------------------------------------
step 3 "Download wipe-station binary"

BINARY_URL="https://github.com/painteau/wipe/releases/latest/download/wipe-station"
SHA256_URL="https://github.com/painteau/wipe/releases/latest/download/wipe-station.sha256"

curl -fsSL "$BINARY_URL" -o /tmp/wipe-station
curl -fsSL "$SHA256_URL" -o /tmp/wipe-station.sha256

# Verify checksum
(cd /tmp && sha256sum -c wipe-station.sha256) || die "SHA256 mismatch — aborting"

install -m 755 /tmp/wipe-station /usr/local/bin/wipe-station
rm -f /tmp/wipe-station /tmp/wipe-station.sha256
ok "Binary installed at /usr/local/bin/wipe-station"

# -----------------------------------------------------------------------------
step 4 "Disable screen blanking"

# Kernel-level (persistent across reboots)
for f in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [[ -f "$f" ]]; then
        if ! grep -q "consoleblank=0" "$f"; then
            sed -i 's/$/ consoleblank=0/' "$f"
            ok "consoleblank=0 added to $f"
        else
            ok "consoleblank=0 already set in $f"
        fi
        break
    fi
done

# -----------------------------------------------------------------------------
step 5 "Configure systemd service"

# Mask getty on tty1 so the station owns it exclusively
systemctl mask getty@tty1.service 2>/dev/null || true

cat > /etc/systemd/system/wipe-station.service << 'SERVICE'
[Unit]
Description=Wipe Station TUI
After=multi-user.target
DefaultDependencies=no

[Service]
ExecStart=/usr/local/bin/wipe-station
Restart=always
RestartSec=2
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable wipe-station.service
ok "Service enabled"

# -----------------------------------------------------------------------------
step 6 "Configure GPIO permissions"

# rppal accesses /dev/gpiomem directly (no pigpiod)
# Running as root (service default) — no extra config needed
if ! ls /dev/gpiomem &>/dev/null; then
    echo -e "  ${RED}Warning: /dev/gpiomem not found — GPIO may not work on this hardware${NC}"
else
    ok "/dev/gpiomem available"
fi

# -----------------------------------------------------------------------------
step 7 "Done — rebooting in 5 seconds"

echo -e "\n${GREEN}${BOLD}Setup complete.${NC}"
echo    "  Binary   : /usr/local/bin/wipe-station"
echo    "  Service  : systemctl status wipe-station"
echo    "  Logs     : journalctl -u wipe-station -f"
echo    "  Update   : re-run this script, or let auto-update handle it"
echo

sleep 5
reboot
