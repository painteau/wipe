#!/bin/bash
# setup.sh - Install wipe station on Raspberry Pi 4
# Usage: curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/bash/setup.sh | sudo bash

set -e

STATION_URL="https://raw.githubusercontent.com/painteau/wipe/main/bash/station.sh"
STATION_BIN="/usr/local/bin/wipe-station.sh"
SERVICE_FILE="/etc/systemd/system/wipe-station.service"
UDEV_RULE="/etc/udev/rules.d/99-wipe-no-automount.rules"
USBGUARD_RULES="/etc/usbguard/rules.conf"
STATION_USER="wipestation"
LOG_FILE="/var/log/wipe-station.log"

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
    uhubctl \
    sudo

# --- Create dedicated user
echo -e "${YELLOW}[~] Creating user '${STATION_USER}'...${NC}"
if ! id "$STATION_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$STATION_USER"
fi

# Groups needed:
#   disk    — read/write access to /dev/sda, /dev/sdb (block devices)
#   tty     — access to /dev/tty1 (HDMI display)
#   gpio    — access to GPIO pins via pigpiod
#   video   — framebuffer access
#   plugdev — USB device events
for GROUP in disk tty gpio video plugdev; do
    getent group "$GROUP" &>/dev/null && usermod -aG "$GROUP" "$STATION_USER" || true
done

# sudoers: only allow umount (needed to unmount partitions before dd)
echo -e "${YELLOW}[~] Configuring sudoers...${NC}"
cat > /etc/sudoers.d/wipestation << EOF
# Wipe station — allow umount only, no password
${STATION_USER} ALL=(root) NOPASSWD: /bin/umount, /sbin/umount
EOF
chmod 440 /etc/sudoers.d/wipestation

# Log file owned by station user
touch "$LOG_FILE"
chown "$STATION_USER":"$STATION_USER" "$LOG_FILE"

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
echo -e "${YELLOW}[~] Configuring USBGuard (storage only)...${NC}"
mkdir -p /etc/usbguard

cat > "$USBGUARD_RULES" << 'EOF'
# Wipe station USB policy
allow with-interface equals { 09:00:00 }
allow with-interface equals { 08:*:* }
block
EOF

cat > /etc/usbguard/usbguard-daemon.conf << EOF
RuleFile=/etc/usbguard/rules.conf
ImplicitPolicyTarget=block
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
InsertedDevicePolicy=apply-policy
RestoreControllerDeviceState=false
DeviceManagerBackend=uevent
IPCAllowedUsers=root ${STATION_USER}
IPCAllowedGroups=root
DeviceRulesWithPort=false
EOF

systemctl enable usbguard
systemctl start usbguard || true

# --- Enable SSH for remote maintenance
echo -e "${YELLOW}[~] Enabling SSH...${NC}"
systemctl enable ssh
systemctl start ssh

# --- Download station.sh
echo -e "${YELLOW}[~] Downloading station.sh...${NC}"
curl -fsSL "$STATION_URL" -o "$STATION_BIN"
chmod +x "$STATION_BIN"
chown "$STATION_USER":"$STATION_USER" "$STATION_BIN"

# --- Systemd service (runs as wipestation, not root)
echo -e "${YELLOW}[~] Creating systemd service...${NC}"
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Wipe Station
After=network-online.target usbguard.service pigpiod.service
Wants=network-online.target

[Service]
Type=simple
User=${STATION_USER}
Group=${STATION_USER}
ExecStart=${STATION_BIN}
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

# --- Auto-login on tty1 as wipestation
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${STATION_USER} --noclear %I \$TERM
EOF

systemctl daemon-reload

# --- pigpiod for GPIO
systemctl enable pigpiod
systemctl start pigpiod

# --- Summary
echo ""
echo -e "${GREEN}[✓] Setup complete.${NC}"
echo ""
echo -e "  ${DIM}Utilisateur  :${NC} ${STATION_USER} (pas root)"
echo -e "  ${DIM}Groupes      :${NC} disk, tty, gpio, video, plugdev"
echo -e "  ${DIM}sudo autorisé:${NC} umount uniquement"
echo ""
echo -e "  ${DIM}USB autorisé :${NC} stockage + hubs"
echo -e "  ${DIM}USB bloqué   :${NC} HID, BadUSB, tout autre"
echo ""
echo -e "  ${DIM}SSH activé — IP :${NC} $(hostname -I | awk '{print $1}')"
echo ""
echo -e "${GREEN}[✓] Reboot : reboot${NC}"
