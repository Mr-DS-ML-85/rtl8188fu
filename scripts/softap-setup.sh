#!/bin/bash
# Soft AP Setup - Create a WiFi access point with RTL8188FU
# Usage: ./softap-setup.sh <interface> <ssid> <password> [channel]

IFACE=$1
SSID=$2
PASSWORD=$3
CHANNEL=${4:-6}

if [ -z "$IFACE" ] || [ -z "$SSID" ] || [ -z "$PASSWORD" ]; then
    echo "Usage: $0 <interface> <ssid> <password> [channel]"
    echo "  interface - Network interface (e.g., wlan0)"
    echo "  ssid      - WiFi network name"
    echo "  password  - WiFi password (min 8 characters)"
    echo "  channel   - Optional: channel number (default: 6)"
    exit 1
fi

echo "=========================================="
echo "    RTL8188FU Soft AP Setup v1.0"
echo "=========================================="
echo ""

# Check password length
if [ ${#PASSWORD} -lt 8 ]; then
    echo "[!] Error: Password must be at least 8 characters"
    exit 1
fi

echo "[*] Interface: $IFACE"
echo "[*] SSID: $SSID"
echo "[*] Channel: $CHANNEL"
echo ""

# Install required packages
echo "[*] Installing required packages..."
sudo apt-get update
sudo apt-get install -y hostapd dnsmasq

# Stop services
echo "[*] Stopping services..."
sudo systemctl stop hostapd 2>/dev/null
sudo systemctl stop dnsmasq 2>/dev/null

# Configure hostapd
echo "[*] Configuring hostapd..."
cat > /tmp/hostapd.conf << EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Configure dnsmasq
echo "[*] Configuring dnsmasq..."
cat > /tmp/dnsmasq.conf << EOF
interface=$IFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
dhcp-option=option:router,192.168.4.1
dhcp-option=option:dns-server,8.8.8.8,8.8.4.4
EOF

# Configure network interface
echo "[*] Configuring network interface..."
sudo ip link set $IFACE down
sudo ip addr add 192.168.4.1/24 dev $IFACE
sudo ip link set $IFACE up

# Enable IP forwarding
echo "[*] Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1

# Configure iptables for NAT
echo "[*] Configuring NAT..."
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i $IFACE -o eth0 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o $IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT

# Start hostapd
echo "[*] Starting hostapd..."
sudo hostapd /tmp/hostapd.conf &
HOSTAPD_PID=$!

# Start dnsmasq
echo "[*] Starting dnsmasq..."
sudo dnsmasq -C /tmp/dnsmasq.conf &
DNSMASQ_PID=$!

echo ""
echo "=========================================="
echo "    Soft AP Started Successfully!"
echo "=========================================="
echo ""
echo "SSID: $SSID"
echo "Password: $PASSWORD"
echo "Channel: $CHANNEL"
echo "Gateway: 192.168.4.1"
echo "DHCP Range: 192.168.4.2 - 192.168.4.20"
echo ""
echo "hostapd PID: $HOSTAPD_PID"
echo "dnsmasq PID: $DNSMASQ_PID"
echo ""
echo "[*] To stop the AP:"
echo "    sudo kill $HOSTAPD_PID $DNSMASQ_PID"
echo "    sudo ip addr del 192.168.4.1/24 dev $IFACE"
echo "    sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE"
echo ""
echo "[*] To monitor connected clients:"
echo "    sudo hostapd_cli all_sta"
echo ""
echo "[*] To view DHCP leases:"
echo "    cat /var/lib/misc/dnsmasq.leases"
