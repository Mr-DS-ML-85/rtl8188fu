#!/bin/bash
# WiFi Scanner - Passive WiFi analysis tool for RTL8188FU
# Usage: ./wifi-scanner.sh <interface> [channel]

IFACE=$1
CHANNEL=$2

if [ -z "$IFACE" ]; then
    echo "Usage: $0 <interface> [channel]"
    echo "  interface - Monitor mode interface (e.g., wlan0mon)"
    echo "  channel   - Optional: specific channel to scan (default: all channels)"
    exit 1
fi

echo "=========================================="
echo "    RTL8188FU WiFi Scanner v1.0"
echo "=========================================="
echo ""

# Check if interface is in monitor mode
MODE=$(iw dev $IFACE info 2>/dev/null | grep "type" | awk '{print $2}')
if [ "$MODE" != "monitor" ]; then
    echo "[!] Error: $IFACE is not in monitor mode"
    echo "[*] Enable monitor mode first: ./airmon-ng.sh start $IFACE"
    exit 1
fi

echo "[*] Interface: $IFACE"
echo "[*] Mode: $MODE"
echo ""

# Set channel if specified
if [ ! -z "$CHANNEL" ]; then
    echo "[*] Setting channel to $CHANNEL..."
    sudo iw dev $IFACE set channel $CHANNEL
    echo "[*] Channel set to $CHANNEL"
fi

echo "[*] Starting passive scan for 30 seconds..."
echo "[*] Press Ctrl+C to stop"
echo ""

# Run airodump-ng for passive scanning
sudo timeout 30 airodump-ng --manufacturer --wps --output-format csv -w /tmp/wifi_scan $IFACE 2>/dev/null

echo ""
echo "[*] Scan complete!"
echo "[*] Results saved to /tmp/wifi_scan-01.csv"
echo ""

# Parse and display results
if [ -f "/tmp/wifi_scan-01.csv" ]; then
    echo "=========================================="
    echo "    Discovered Networks"
    echo "=========================================="
    echo ""
    
    # Extract and display networks
    awk -F',' '
    NR > 1 && NF >= 14 {
        if ($1 != "BSSID" && $1 != "") {
            printf "BSSID: %s\n", $1
            printf "Channel: %s\n", $4
            printf "Speed: %s\n", $5
            printf "Privacy: %s\n", $6
            printf "Cipher: %s\n", $7
            printf "Auth: %s\n", $8
            printf "Power: %s dBm\n", $9
            printf "Beacons: %s\n", $10
            printf "Data: %s\n", $11
            printf "ESSID: %s\n", $14
            printf "---\n"
        }
    }' /tmp/wifi_scan-01.csv
    
    echo ""
    echo "[*] Total networks found: $(grep -c "^" /tmp/wifi_scan-01.csv 2>/dev/null || echo 0)"
fi

echo ""
echo "[*] For detailed analysis:"
echo "    cat /tmp/wifi_scan-01.csv"
echo ""
echo "[*] To capture packets:"
echo "    airodump-ng -c <channel> --bssid <BSSID> -w capture $IFACE"
