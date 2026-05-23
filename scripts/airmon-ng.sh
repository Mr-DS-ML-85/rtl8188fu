#!/bin/bash
# airmon-ng compatibility script for RTL8188FU
# Usage: ./airmon-ng.sh <start|stop|check> <interface>

ACTION=$1
IFACE=$2

if [ -z "$ACTION" ] || [ -z "$IFACE" ]; then
    echo "Usage: $0 <start|stop|check> <interface>"
    echo "  start <iface>  - Enable monitor mode"
    echo "  stop <iface>   - Disable monitor mode (back to managed)"
    echo "  check          - Kill interfering processes"
    exit 1
fi

case $ACTION in
    start)
        echo "[*] Enabling monitor mode on $IFACE..."
        
        # Kill interfering processes
        echo "[*] Killing interfering processes..."
        sudo airmon-ng check kill 2>/dev/null || true
        
        # Bring interface down
        sudo ip link set $IFACE down
        
        # Set monitor mode
        sudo iw dev $IFACE set type monitor
        
        # Bring interface up
        sudo ip link set $IFACE up
        
        # Set channel (optional, default channel 1)
        if [ ! -z "$3" ]; then
            sudo iw dev $IFACE set channel $3
            echo "[*] Channel set to $3"
        fi
        
        echo "[+] Monitor mode enabled on $IFACE"
        echo "[+] Interface is now: ${IFACE}mon"
        echo ""
        echo "Usage examples:"
        echo "  airodump-ng ${IFACE}mon"
        echo "  aireplay-ng -9 ${IFACE}mon"
        echo "  airodump-ng -c 6 --bssid AA:BB:CC:DD:EE:FF -w capture ${IFACE}mon"
        ;;
        
    stop)
        echo "[*] Disabling monitor mode on $IFACE..."
        
        # Bring interface down
        sudo ip link set $IFACE down
        
        # Set managed mode
        sudo iw dev $IFACE set type managed
        
        # Bring interface up
        sudo ip link set $IFACE up
        
        # Restart NetworkManager
        sudo systemctl start NetworkManager 2>/dev/null || true
        
        echo "[+] Monitor mode disabled on $IFACE"
        echo "[+] Interface is now in managed mode"
        ;;
        
    check)
        echo "[*] Checking for interfering processes..."
        
        # List processes that might interfere
        echo ""
        echo "Processes that might interfere with monitor mode:"
        echo "================================================"
        
        # Check for NetworkManager
        if pgrep -x "NetworkManager" > /dev/null; then
            echo "[!] NetworkManager is running"
            echo "    Fix: sudo systemctl stop NetworkManager"
        fi
        
        # Check for wpa_supplicant
        if pgrep -x "wpa_supplicant" > /dev/null; then
            echo "[!] wpa_supplicant is running"
            echo "    Fix: sudo killall wpa_supplicant"
        fi
        
        # Check for dhclient
        if pgrep -x "dhclient" > /dev/null; then
            echo "[!] dhclient is running"
            echo "    Fix: sudo killall dhclient"
        fi
        
        echo ""
        echo "[*] To kill all interfering processes:"
        echo "    sudo airmon-ng check kill"
        ;;
        
    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $0 <start|stop|check> <interface>"
        exit 1
        ;;
esac
