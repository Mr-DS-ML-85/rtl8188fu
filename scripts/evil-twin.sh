#!/bin/bash
# Evil Twin AP - Creates a rogue access point for security testing
# Usage: sudo ./scripts/evil-twin.sh <interface> <ssid> [channel] [password]
#
# Examples:
#   sudo ./scripts/evil-twin.sh wlan0 "FreeWiFi" 6              # Open AP
#   sudo ./scripts/evil-twin.sh wlan0 "TargetNet" 1 "pass123"   # WPA2 AP
#
# Dependencies: hostapd, dnsmasq
# Install: sudo apt install hostapd dnsmasq

set -e

IFACE="${1:?Usage: $0 <interface> <ssid> [channel] [password]}"
SSID="${2:?Usage: $0 <interface> <ssid> [channel] [password]}"
CHANNEL="${3:-6}"
PASSWORD="${4:-}"
AP_IP="10.0.0.1"
AP_NET="10.0.0.0/24"
CONF_DIR="/tmp/evil-twin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo -e "\n${YELLOW}[*] Cleaning up...${NC}"
    killall hostapd dnsmasq 2>/dev/null || true
    ip link set "$IFACE" down 2>/dev/null || true
    iw dev "$IFACE" set type managed 2>/dev/null || true
    ip addr flush dev "$IFACE" 2>/dev/null || true
    ip link set "$IFACE" up 2>/dev/null || true
    echo -e "${GREEN}[+] Cleanup complete${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Evil Twin AP - RTL8188FU       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[-] Must run as root (sudo)${NC}"
    exit 1
fi

# Check dependencies
for cmd in hostapd dnsmasq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[-] $cmd not found. Install: sudo apt install hostapd dnsmasq${NC}"
        exit 1
    fi
done

# Kill existing processes
killall hostapd dnsmasq 2>/dev/null || true
sleep 1

# Setup interface
echo -e "${YELLOW}[*] Setting up $IFACE...${NC}"
ip link set "$IFACE" down
iw dev "$IFACE" set type managed
ip addr flush dev "$IFACE"
ip addr add "$AP_IP/24" dev "$IFACE"
ip link set "$IFACE" up
sleep 1

# Create config directory
mkdir -p "$CONF_DIR"

# Generate hostapd config
echo -e "${YELLOW}[*] Creating AP: $SSID on channel $CHANNEL${NC}"
if [[ -n "$PASSWORD" ]]; then
    echo -e "${YELLOW}[*] Security: WPA2-PSK${NC}"
    cat > "$CONF_DIR/hostapd.conf" << EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
macaddr_acl=0
auth_algs=1
logger_stdout=-1
logger_stdout_level=2
EOF
else
    echo -e "${YELLOW}[*] Security: OPEN (no password)${NC}"
    cat > "$CONF_DIR/hostapd.conf" << EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
auth_algs=1
wpa=0
macaddr_acl=0
logger_stdout=-1
logger_stdout_level=2
EOF
fi

# Start dnsmasq
echo -e "${YELLOW}[*] Starting DHCP server...${NC}"
dnsmasq \
    --interface="$IFACE" \
    --bind-interfaces \
    --dhcp-range=10.0.0.10,10.0.0.50,255.255.255.0,12h \
    --dhcp-option=3,"$AP_IP" \
    --dhcp-option=6,8.8.8.8 \
    --no-daemon &
DNSMASQ_PID=$!
sleep 1

# Start hostapd
echo -e "${YELLOW}[*] Starting hostapd...${NC}"
hostapd "$CONF_DIR/hostapd.conf" &
HOSTAPD_PID=$!
sleep 2

# Verify
if kill -0 "$HOSTAPD_PID" 2>/dev/null; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Evil Twin AP is LIVE!        ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  SSID:     $SSID${NC}"
    echo -e "${GREEN}║  Channel:  $CHANNEL${NC}"
    echo -e "${GREEN}║  Gateway:  $AP_IP${NC}"
    echo -e "${GREEN}║  DHCP:     10.0.0.10 - 10.0.0.50${NC}"
    if [[ -n "$PASSWORD" ]]; then
    echo -e "${GREEN}║  Password: $PASSWORD${NC}"
    else
    echo -e "${GREEN}║  Security: OPEN${NC}"
    fi
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}[*] Press Ctrl+C to stop${NC}"
    echo ""
    
    # Wait for hostapd
    wait "$HOSTAPD_PID"
else
    echo -e "${RED}[-] hostapd failed to start!${NC}"
    cleanup
fi
