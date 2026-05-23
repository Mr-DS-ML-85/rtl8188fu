#!/bin/bash
# Deauth Detector - Detect deauthentication attacks on your WiFi
# Usage: ./deauth-detector.sh <interface> [target_bssid]

IFACE=$1
TARGET_BSSID=$2

if [ -z "$IFACE" ]; then
    echo "Usage: $0 <interface> [target_bssid]"
    echo "  interface    - Monitor mode interface (e.g., wlan0mon)"
    echo "  target_bssid - Optional: specific BSSID to monitor (default: all)"
    exit 1
fi

echo "=========================================="
echo "    RTL8188FU Deauth Detector v1.0"
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
echo "[*] Monitoring for deauthentication attacks..."
echo "[*] Press Ctrl+C to stop"
echo ""

# Create log file
LOG_FILE="/tmp/deauth-$(date +%Y%m%d-%H%M%S).log"
echo "[*] Logging to: $LOG_FILE"
echo ""

# Function to detect deauth frames
detect_deauth() {
    sudo timeout 60 tcpdump -i $IFACE -l -e 'type mgt subtype deauth' 2>/dev/null | while read line; do
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$TIMESTAMP] DEAUTH DETECTED: $line"
        echo "[$TIMESTAMP] DEAUTH DETECTED: $line" >> $LOG_FILE
        
        # Extract source and destination
        SRC=$(echo "$line" | grep -oP '(?<=SA:)[0-9a-f:]{17}' | head -1)
        DST=$(echo "$line" | grep -oP '(?<=DA:)[0-9a-f:]{17}' | head -1)
        
        if [ ! -z "$SRC" ] && [ ! -z "$DST" ]; then
            echo "  Source: $SRC"
            echo "  Destination: $DST"
            echo ""
        fi
    done
}

# Function to detect disassociation frames
detect_disassoc() {
    sudo timeout 60 tcpdump -i $IFACE -l -e 'type mgt subtype disassoc' 2>/dev/null | while read line; do
        TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$TIMESTAMP] DISASSOC DETECTED: $line"
        echo "[$TIMESTAMP] DISASSOC DETECTED: $line" >> $LOG_FILE
    done
}

# Run detection in parallel
echo "[*] Starting deauth detection (60 second sample)..."
echo ""

detect_deauth &
detect_disassoc &

# Wait for user interrupt
wait

echo ""
echo "[*] Detection complete!"
echo "[*] Log file: $LOG_FILE"
echo ""
echo "[*] To analyze the log:"
echo "    cat $LOG_FILE"
echo ""
echo "[*] To count deauth frames:"
echo "    grep -c 'DEAUTH DETECTED' $LOG_FILE"
