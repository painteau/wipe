#!/bin/bash
# setup.sh - Install wipe station on Raspberry Pi 4
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/live/setup.sh | sudo bash

set -e

STATION_URL="https://raw.githubusercontent.com/painteau/wipe/main/live/station.sh"
STATION_BIN="/usr/local/bin/wipe-station.sh"
SERVICE_FILE="/etc/systemd/system/wipe-station.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[!] Run as root${NC}"
    exit 1
fi

echo -e "${CYAN}[*] Installing wipe station...${NC}"

# --- Dependencies
echo -e "${YELLOW}[~] Installing dependencies...${NC}"
apt-get update -qq
apt-get install -y --no-install-recommends \
    tmux \
    curl \
    util-linux \
    coreutils \
    python3-gpiozero \
    python3-pigpio \
    pigpio

# --- Download station.sh
echo -e "${YELLOW}[~] Downloading station.sh...${NC}"
curl -fsSL "$STATION_URL" -o "$STATION_BIN"
chmod +x "$STATION_BIN"

# --- Systemd service
echo -e "${YELLOW}[~] Creating systemd service...${NC}"
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Wipe Station
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wipe-station.sh
Restart=always
RestartSec=5
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wipe-station.service

# --- Auto-login on tty1 (for display on HDMI)
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF

systemctl daemon-reload

# --- pigpiod for GPIO
systemctl enable pigpiod
systemctl start pigpiod

echo -e "${GREEN}[✓] Setup complete.${NC}"
echo -e "${GREEN}[✓] Reboot to start the station: reboot${NC}"
