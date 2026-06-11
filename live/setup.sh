#!/bin/bash
# setup.sh - Install wipe station on Raspberry Pi 4
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/live/setup.sh | sudo bash

set -e

STATION_URL="https://raw.githubusercontent.com/painteau/wipe/main/live/station.sh"
STATION_BIN="/usr/local/bin/wipe-station.sh"
SERVICE_FILE="/etc/systemd/system/wipe-station.service"
UDEV_RULE="/etc/udev/rules.d/99-wipe-no-automount.rules"
USBGUARD_RULES="/etc/usbguard/rules.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
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
    pigpio \
    usbguard \
    uhubctl

# --- Disable udisks2 (automount daemon)
echo -e "${YELLOW}[~] Disabling udisks2 automount...${NC}"
systemctl stop udisks2 2>/dev/null || true
systemctl disable udisks2 2>/dev/null || true
systemctl mask udisks2 2>/dev/null || true

# --- udev rule: block automount on all USB block devices
echo -e "${YELLOW}[~] Installing udev no-automount rule...${NC}"
cat > "$UDEV_RULE" << 'EOF'
# Wipe station — never automount USB storage
SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"
SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{UDISKS_PRESENTATION_HIDE}="1"
EOF

udevadm control --reload-rules
udevadm trigger --subsystem-match=block

# --- USBGuard: allow USB hubs + storage only, block everything else
# Protects against BadUSB, Rubber Ducky, HID injection, rogue devices.
echo -e "${YELLOW}[~] Configuring USBGuard (storage only)...${NC}"
mkdir -p /etc/usbguard

cat > "$USBGUARD_RULES" << 'EOF'
# Wipe station USB policy
# Allow USB hubs (needed for multi-port docks)
allow with-interface equals { 09:00:00 }
# Allow USB mass storage (HDD/SSD docks)
allow with-interface equals { 08:*:* }
# Block everything else (HID, network, serial, BadUSB...)
block
EOF

# Apply USBGuard config: enforce policy on connect
cat > /etc/usbguard/usbguard-daemon.conf << 'EOF'
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
DeviceManagerBackend=uevent
IPCAllowedUsers=root
IPCAllowedGroups=root
DeviceRulesWithPort=false
EOF

systemctl enable usbguard
systemctl start usbguard || true

# --- Enable SSH for remote maintenance (no USB keyboard needed)
echo -e "${YELLOW}[~] Enabling SSH...${NC}"
systemctl enable ssh
systemctl start ssh

# --- Download station.sh
echo -e "${YELLOW}[~] Downloading station.sh...${NC}"
curl -fsSL "$STATION_URL" -o "$STATION_BIN"
chmod +x "$STATION_BIN"

# --- Systemd service
echo -e "${YELLOW}[~] Creating systemd service...${NC}"
cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Wipe Station
After=network-online.target usbguard.service
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

# --- Auto-login on tty1
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

# --- Summary
echo ""
echo -e "${GREEN}[✓] Setup complete.${NC}"
echo ""
echo -e "  ${DIM}USB policy (USBGuard):${NC}"
echo -e "  ${GREEN}  [+]${NC} ${DIM}USB hubs        — allowed${NC}"
echo -e "  ${GREEN}  [+]${NC} ${DIM}USB storage      — allowed${NC}"
echo -e "  ${RED}  [-]${NC} ${DIM}HID (clavier/souris/BadUSB) — blocked${NC}"
echo -e "  ${RED}  [-]${NC} ${DIM}Tout autre périphérique     — blocked${NC}"
echo ""
echo -e "  ${DIM}SSH activé pour maintenance à distance.${NC}"
echo -e "  ${DIM}Trouver l'IP : hostname -I${NC}"
echo ""
echo -e "${GREEN}[✓] Reboot : reboot${NC}"
