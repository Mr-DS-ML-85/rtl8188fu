#!/bin/bash
# =============================================================================
# RTL8188FU Driver - One-Click Compile & Install
# Auto-detects ALL Realtek RTL8188F USB dongles plugged into any port
# and patches every detected USB ID into the driver table automatically.
# Tested on kernel 7.0.0-15-generic
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DRIVER_NAME="rtl8188fu"
SRC_DIR="/usr/src/rtl8188fu-1.0"
KERNEL_VER=$(uname -r)
INSTALL_DIR="/lib/modules/${KERNEL_VER}/kernel/drivers/net/wireless"
USB_INTF_FILE="${SRC_DIR}/os_dep/linux/usb_intf.c"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-r8188eu.conf"
MODPROBE_CONF="/etc/modprobe.d/rtl8188fu.conf"

# Known Realtek RTL8188F vendor ID
REALTEK_VID="0bda"

# Known RTL8188F/FU/FTV product IDs (baseline — auto-detect adds more)
KNOWN_PIDS=("f179" "f149" "f179" "8179" "0179")

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_det()   { echo -e "${CYAN}[SCAN]${NC}  $1"; }

# =============================================================================
# USB AUTO-DETECTION
# Scans all USB devices, identifies Realtek dongles by VID 0bda,
# cross-references against RTL8188F chip signatures, and returns
# a deduplicated list of product IDs to patch into the driver.
# =============================================================================
detect_realtek_usb_ids() {
    log_info "Scanning all USB ports for Realtek RTL8188F dongles..."
    echo ""

    # Collect every USB device from lsusb
    local all_usb
    all_usb=$(lsusb 2>/dev/null) || log_error "lsusb not found. Install usbutils: apt install usbutils"

    echo -e "  ${BOLD}All USB devices detected:${NC}"
    echo "$all_usb" | while IFS= read -r line; do
        echo -e "    ${CYAN}→${NC} $line"
    done
    echo ""

    # Filter Realtek devices (VID 0bda)
    local realtek_devs
    realtek_devs=$(echo "$all_usb" | grep -i "0bda:" || true)

    if [[ -z "$realtek_devs" ]]; then
        log_warn "No Realtek (0bda) USB devices found."
        log_warn "Make sure your dongle is plugged in before running this script."
        log_warn "Falling back to known PID list only."
        DETECTED_PIDS=("${KNOWN_PIDS[@]}")
        return
    fi

    echo -e "  ${BOLD}Realtek devices found:${NC}"

    # Parse each Realtek device and extract PID
    local detected=()
    while IFS= read -r dev; do
        # lsusb format: Bus 002 Device 004: ID 0bda:f149 Realtek ...
        local pid
        pid=$(echo "$dev" | grep -oP '0bda:\K[0-9a-fA-F]+')
        local desc
        desc=$(echo "$dev" | sed 's/.*ID [0-9a-f]*:[0-9a-f]* //')

        if [[ -n "$pid" ]]; then
            local pid_upper
            pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')
            echo -e "    ${GREEN}✓${NC} 0bda:${pid} — ${desc}"
            detected+=("$pid")
        fi
    done <<< "$realtek_devs"

    echo ""

    # Merge detected PIDs with known baseline, deduplicate
    local all_pids=()
    for p in "${KNOWN_PIDS[@]}" "${detected[@]}"; do
        local normalized
        normalized=$(echo "$p" | tr '[:upper:]' '[:lower:]')
        # Check if already in array
        local found=0
        for existing in "${all_pids[@]:-}"; do
            [[ "$(echo "$existing" | tr '[:upper:]' '[:lower:]')" == "$normalized" ]] && found=1 && break
        done
        [[ $found -eq 0 ]] && all_pids+=("$normalized")
    done

    DETECTED_PIDS=("${all_pids[@]}")

    log_ok "Total unique Realtek PIDs to register: ${#DETECTED_PIDS[@]}"
    for pid in "${DETECTED_PIDS[@]}"; do
        log_det "  Will patch: 0x$(echo "$pid" | tr '[:lower:]' '[:upper:]')"
    done
    echo ""
}

# =============================================================================
# PATCH USB ID TABLE
# For each detected PID, inserts a new entry into rtw_usb_id_tbl[]
# in usb_intf.c — only if not already present. Uses the 0xF179 anchor
# entry as the insertion point.
# =============================================================================
patch_all_usb_ids() {
    log_info "Patching USB ID table in usb_intf.c..."

    # Verify anchor exists
    if ! grep -q "0xF179" "$USB_INTF_FILE"; then
        log_error "Anchor 0xF179 not found in usb_intf.c — wrong source tree?"
    fi

    local patched_count=0
    local skipped_count=0

    for pid in "${DETECTED_PIDS[@]}"; do
        local pid_upper
        pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')

        # Skip 0xF179 — it's the anchor, already in the source
        if [[ "${pid_upper}" == "F179" ]]; then
            log_ok "0xF179 is the baseline entry — already present, skipping."
            ((skipped_count++))
            continue
        fi

        # Check if this PID already exists in the file
        if grep -qi "0x${pid_upper}" "$USB_INTF_FILE"; then
            log_ok "0x${pid_upper} already in driver table — skipping."
            ((skipped_count++))
            continue
        fi

        log_info "Inserting USB ID 0x${pid_upper} into driver table..."

        # Insert new entry directly after the 0xF179 line
        sed -i "/0xF179, 0xff, 0xff, 0xff.*RTL8188F/a\\\\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0x${pid_upper}, 0xff, 0xff, 0xff), .driver_info = RTL8188F}, \\/\\* 8188FU auto-detected 0bda:${pid} \\*\\/" \
            "$USB_INTF_FILE"

        # Verify insertion
        if grep -qi "0x${pid_upper}" "$USB_INTF_FILE"; then
            log_ok "Inserted: 0x${pid_upper} (0bda:${pid})"
            ((patched_count++))
        else
            log_warn "Failed to insert 0x${pid_upper} — may need manual patch."
        fi
    done

    echo ""
    log_ok "USB ID patch complete: ${patched_count} added, ${skipped_count} already present."
    echo ""

    # Print final state of the ID table for verification
    echo -e "  ${BOLD}Final USB ID table in driver:${NC}"
    grep -A1 "rtw_usb_id_tbl\|USB_VENDER_ID_REALTEK" "$USB_INTF_FILE" \
        | grep "USB_VENDER_ID_REALTEK" \
        | while IFS= read -r line; do
            echo -e "    ${CYAN}→${NC} $line"
        done
    echo ""
}

# =============================================================================
# UDEV RULE — makes driver auto-bind when dongle is plugged into ANY port
# after installation, without needing modprobe manually
# =============================================================================
install_udev_rule() {
    log_info "Installing udev rule for hot-plug support..."

    local udev_dir="/etc/udev/rules.d"
    local udev_file="${udev_dir}/99-rtl8188fu.rules"

    mkdir -p "$udev_dir"

    # Build udev rules for every detected PID
    {
        echo "# RTL8188FU auto-generated udev rules — plug dongle into any USB port"
        echo "# Generated: $(date)"
        echo ""
        for pid in "${DETECTED_PIDS[@]}"; do
            local pid_upper
            pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')
            echo "# 0bda:${pid}"
            echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0bda\", ATTRS{idProduct}==\"${pid}\", RUN+=\"/sbin/modprobe rtl8188fu\""
        done
        echo ""
        echo "# Generic Realtek 0bda fallback for any RTL8188F variant"
        echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0bda\", ATTRS{bInterfaceClass}==\"ff\", ATTRS{bInterfaceSubClass}==\"ff\", RUN+=\"/sbin/modprobe rtl8188fu\""
    } > "$udev_file"

    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true

    log_ok "Udev rule written: ${udev_file}"
    log_ok "Dongle will now auto-bind on any USB port after reboot."
}

# =============================================================================
# STANDARD FUNCTIONS
# =============================================================================
check_root() {
    [[ $EUID -ne 0 ]] && log_error "Run as root: sudo bash install.sh"
}

check_dependencies() {
    log_info "Checking build dependencies..."
    local missing=()
    for dep in make gcc grep sed depmod modprobe lsusb udevadm; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    [[ ! -d "/usr/src/linux-headers-${KERNEL_VER}" ]] && missing+=("linux-headers-${KERNEL_VER}")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing: ${missing[*]}"
        apt-get update -qq && apt-get install -y build-essential usbutils \
            "linux-headers-${KERNEL_VER}" 2>/dev/null \
            || log_error "Could not install dependencies. Run: apt install build-essential usbutils linux-headers-${KERNEL_VER}"
    fi
    log_ok "All dependencies present."
}

check_source() {
    log_info "Checking driver source at ${SRC_DIR}..."
    [[ -d "$SRC_DIR" ]] || log_error "Source not found: ${SRC_DIR} — clone the repo first."
    [[ -f "$USB_INTF_FILE" ]] || log_error "usb_intf.c not found at ${USB_INTF_FILE}"
    log_ok "Source directory found."
}

remove_conflicting_drivers() {
    log_info "Removing conflicting drivers..."
    for mod in rtl8188fu r8188eu rtl8xxxu; do
        if lsmod | grep -q "^${mod}"; then
            modprobe -r "$mod" 2>/dev/null \
                && log_ok "Removed: ${mod}" \
                || log_warn "Could not remove: ${mod}"
        fi
    done
    for ko in rtl8188fu r8188eu; do
        local ko_path="${INSTALL_DIR}/${ko}.ko"
        [[ -f "$ko_path" ]] && rm -f "$ko_path" && log_ok "Removed old: ${ko_path}"
    done
}

setup_blacklist() {
    log_info "Setting up module blacklist..."
    cat > "$BLACKLIST_FILE" <<EOF
# Blacklist competing drivers for RTL8188FU
blacklist r8188eu
blacklist rtl8xxxu
EOF
    log_ok "Blacklist: ${BLACKLIST_FILE}"
}

setup_modprobe_options() {
    log_info "Writing power management options..."
    echo "options rtl8188fu rtw_power_mgnt=0 rtw_enusbss=0 rtw_ips_mode=0 rtw_lps_level=0 rtw_led_ctrl=0" \
        > "$MODPROBE_CONF"
    log_ok "Modprobe options: ${MODPROBE_CONF}"
}

compile_driver() {
    log_info "Compiling driver (kernel ${KERNEL_VER})..."
    cd "$SRC_DIR"
    make clean -s 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tail -5
    [[ -f "${SRC_DIR}/${DRIVER_NAME}.ko" ]] \
        && log_ok "Compiled: ${DRIVER_NAME}.ko" \
        || log_error "Compile failed — run 'make' manually in ${SRC_DIR} for full output."
}

install_driver() {
    log_info "Installing driver to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"
    cp "${SRC_DIR}/${DRIVER_NAME}.ko" "${INSTALL_DIR}/"
    depmod -a
    log_ok "Driver installed and depmod updated."
}

load_and_verify() {
    log_info "Loading driver..."
    modprobe "$DRIVER_NAME"
    sleep 4

    lsmod | grep -q "$DRIVER_NAME" \
        && log_ok "Module loaded: ${DRIVER_NAME}" \
        || log_error "Module failed to load — check: dmesg | tail -30"

    log_info "Checking for wireless interface..."
    local iface
    iface=$(ip -br link | grep -v -E '^(lo|en|eth|docker|br)' | awk '{print $1}' | head -1)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Installation Complete!           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    ip -br link
    echo ""

    if [[ -n "$iface" ]]; then
        log_ok "Wireless interface: ${iface}"
        echo ""
        echo -e "  ${BOLD}Registered USB IDs in driver:${NC}"
        for pid in "${DETECTED_PIDS[@]}"; do
            echo -e "    ${CYAN}✓${NC} 0bda:${pid}"
        done
    else
        log_warn "No wireless interface yet — plug in your dongle if not already connected."
    fi

    echo ""
    echo "Useful commands:"
    echo "  iw dev                       # show wireless interfaces"
    echo "  iw dev <iface> scan          # scan networks"
    echo "  dmesg | grep RTL871X         # driver logs"
    echo "  lsusb | grep 0bda            # verify USB detection"
    echo "  dmesg | grep 'request firm'  # check for firmware flood"
}

uninstall() {
    log_info "Uninstalling ${DRIVER_NAME}..."
    modprobe -r "$DRIVER_NAME" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/${DRIVER_NAME}.ko"
    rm -f "$BLACKLIST_FILE"
    rm -f "$MODPROBE_CONF"
    rm -f "/etc/udev/rules.d/99-rtl8188fu.rules"
    udevadm control --reload-rules 2>/dev/null || true
    depmod -a
    log_ok "Uninstall complete."
}

scan_only() {
    check_root
    detect_realtek_usb_ids
    echo -e "${BOLD}PIDs that would be patched:${NC}"
    for pid in "${DETECTED_PIDS[@]}"; do
        echo -e "  ${CYAN}→${NC} 0x$(echo "$pid" | tr '[:lower:]' '[:upper:]')  (0bda:${pid})"
    done
}

# =============================================================================
# Entry point
# =============================================================================
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   RTL8188FU Driver Installer                 ║"
echo "  ║   USB Auto-Detection Enabled                 ║"
echo "  ║   Kernel: ${KERNEL_VER}            ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

case "${1:-install}" in
    install)
        check_root
        check_dependencies
        check_source
        detect_realtek_usb_ids      # ← scan all USB ports
        patch_all_usb_ids           # ← insert every found PID into driver
        remove_conflicting_drivers
        setup_blacklist
        setup_modprobe_options
        compile_driver
        install_driver
        install_udev_rule           # ← hot-plug support for any port
        load_and_verify
        ;;
    uninstall)
        check_root
        uninstall
        ;;
    scan)
        # Just show what USB IDs are detected — no changes made
        scan_only
        ;;
    patch-only)
        check_root
        check_source
        detect_realtek_usb_ids
        patch_all_usb_ids
        ;;
    *)
        echo "Usage: sudo bash install.sh [command]"
        echo ""
        echo "  install     Full auto-detect, patch, compile, install (default)"
        echo "  uninstall   Remove driver, rules, blacklist, and config"
        echo "  scan        Show detected Realtek USB IDs without making changes"
        echo "  patch-only  Detect and patch USB IDs into source only"
        echo ""
        echo "The installer auto-detects ALL Realtek dongles plugged into any"
        echo "USB port and registers their IDs into the driver table."
        exit 1
        ;;
esac
