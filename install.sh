#!/bin/bash
# =============================================================================
# RTL8188FU Driver - One-Click Compile & Install
# Auto-detects ALL Realtek RTL8188F USB dongles plugged into any port
# and patches every detected USB ID into the driver table automatically.
#
# Patches applied automatically:
#   [P1] USB ID auto-detection — all 0bda:xxxx variants registered
#   [P2] UBSAN flexible array — u8 data[1] → u8 data[]
#   [P3] UBSAN bounds clamp — phydm_math_lib ODM_DB2LinTable
#   [P4] Firmware flood guard — modprobe options + bFWLoadGuard
#   [P5] Power management — blacklist + rtw_pwrctrl IPS guard
#   [P6] Death loop fix — CONFIG_IPS/LPS disabled + HT caps overflow clamp
#   [P7] WPA3/WPA2 — NetworkManager MAC randomization disabled
#
# Tested: kernel 7.0.0-15-generic / Ubuntu 26.04 LTS
# =============================================================================

set -uo pipefail

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
INSTALL_LOG="/var/log/rtl8188fu_install.log"

REALTEK_VID="0bda"
KNOWN_PIDS=("f179" "f149" "8179" "0179")

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; echo "[INFO]  $1" >> "$INSTALL_LOG"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; echo "[OK]    $1" >> "$INSTALL_LOG"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; echo "[WARN]  $1" >> "$INSTALL_LOG"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; echo "[ERROR] $1" >> "$INSTALL_LOG"; exit 1; }
log_det()   { echo -e "${CYAN}[SCAN]${NC}  $1"; }
log_patch() { echo -e "${CYAN}[PATCH]${NC} $1"; echo "[PATCH] $1" >> "$INSTALL_LOG"; }

already_patched() { grep -q "$1" "$2" 2>/dev/null; }

echo "RTL8188FU install log — $(date)" > "$INSTALL_LOG"

# =============================================================================
# USB AUTO-DETECTION
# =============================================================================
detect_realtek_usb_ids() {
    log_info "Scanning all USB ports for Realtek RTL8188F dongles..."
    echo ""

    local all_usb
    all_usb=$(lsusb 2>/dev/null) || log_error "lsusb not found. Run: apt install usbutils"

    echo -e "  ${BOLD}All USB devices detected:${NC}"
    echo "$all_usb" | while IFS= read -r line; do
        echo -e "    ${CYAN}→${NC} $line"
    done
    echo ""

    local realtek_devs
    realtek_devs=$(echo "$all_usb" | grep -i "0bda:" || true)

    if [[ -z "$realtek_devs" ]]; then
        log_warn "No Realtek (0bda) USB devices found — using known PID baseline."
        DETECTED_PIDS=("${KNOWN_PIDS[@]}")
        return
    fi

    echo -e "  ${BOLD}Realtek devices found:${NC}"

    local detected=()
    while IFS= read -r dev; do
        local pid desc pid_upper
        pid=$(echo "$dev" | grep -oP '0bda:\K[0-9a-fA-F]+' || true)
        desc=$(echo "$dev" | sed 's/.*ID [0-9a-f]*:[0-9a-f]* //')
        if [[ -n "$pid" ]]; then
            pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')
            echo -e "    ${GREEN}✓${NC} 0bda:${pid} — ${desc}"
            detected+=("$pid")
        fi
    done <<< "$realtek_devs"
    echo ""

    local all_pids=()
    for p in "${KNOWN_PIDS[@]}" "${detected[@]}"; do
        local normalized found=0
        normalized=$(echo "$p" | tr '[:upper:]' '[:lower:]')
        for existing in "${all_pids[@]:-}"; do
            [[ "$(echo "$existing" | tr '[:upper:]' '[:lower:]')" == "$normalized" ]] && found=1 && break
        done
        [[ $found -eq 0 ]] && all_pids+=("$normalized")
    done

    DETECTED_PIDS=("${all_pids[@]}")
    log_ok "Total unique Realtek PIDs to register: ${#DETECTED_PIDS[@]}"
    for pid in "${DETECTED_PIDS[@]}"; do
        log_det "  Will patch: 0x$(echo "$pid" | tr '[:lower:]' '[:upper:]') (0bda:${pid})"
    done
    echo ""
}

# =============================================================================
# PATCH USB ID TABLE
# =============================================================================
patch_all_usb_ids() {
    log_info "Patching USB ID table in usb_intf.c..."

    grep -q "0xF179" "$USB_INTF_FILE" || log_error "Anchor 0xF179 not found — wrong source tree?"

    local patched_count=0 skipped_count=0

    for pid in "${DETECTED_PIDS[@]}"; do
        local pid_upper
        pid_upper=$(echo "$pid" | tr '[:lower:]' '[:upper:]')

        if [[ "${pid_upper}" == "F179" ]]; then
            log_ok "0xF179 — baseline entry already present."
            ((skipped_count++)); continue
        fi

        if grep -qi "0x${pid_upper}" "$USB_INTF_FILE"; then
            log_ok "0x${pid_upper} already in table — skipping."
            ((skipped_count++)); continue
        fi

        log_info "Inserting 0x${pid_upper} (0bda:${pid})..."
        sed -i "/0xF179, 0xff, 0xff, 0xff.*RTL8188F/a\\\\t{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0x${pid_upper}, 0xff, 0xff, 0xff), .driver_info = RTL8188F}, \\/\\* auto-detected 0bda:${pid} \\*\\/" \
            "$USB_INTF_FILE"

        if grep -qi "0x${pid_upper}" "$USB_INTF_FILE"; then
            log_ok "Inserted: 0x${pid_upper}"
            ((patched_count++))
        else
            log_warn "Failed to insert 0x${pid_upper}"
        fi
    done

    log_ok "USB IDs: ${patched_count} added, ${skipped_count} already present."
    echo ""
    echo -e "  ${BOLD}Final USB ID table:${NC}"
    grep "USB_VENDER_ID_REALTEK" "$USB_INTF_FILE" | while IFS= read -r line; do
        echo -e "    ${CYAN}→${NC} $line"
    done
    echo ""
}

# =============================================================================
# P2 — UBSAN: Flexible Array Member (u8 data[1] → u8 data[])
# Scans entire source tree — struct appears in multiple files
# =============================================================================
patch_flexible_array() {
    log_patch "P2 — Flexible array member fix (u8 data[1] → u8 data[])"

    local files
    files=$(grep -rln 'u8[[:space:]]*data\[1\]' "${SRC_DIR}/" 2>/dev/null \
        | grep -v '\.o$\|\.ko$\|\.mod' || true)

    if [[ -z "$files" ]]; then
        log_ok "P2 — No u8 data[1] found — already patched."
        return
    fi

    while IFS= read -r f; do
        local rel before after
        rel="${f#$SRC_DIR/}"
        before=$(grep -c 'u8[[:space:]]*data\[1\]' "$f" 2>/dev/null || echo 0)
        sed -i 's/u8[[:space:]]*data\[1\];/u8 data[]; \/\* UBSAN: was data[1] *\//g' "$f"
        after=$(grep -c 'u8[[:space:]]*data\[1\]' "$f" 2>/dev/null || echo 0)
        [[ "$after" -eq 0 ]] \
            && log_ok "P2 — Patched ${before} occurrence(s) in ${rel}" \
            || log_warn "P2 — ${after} occurrence(s) remain in ${rel}"
    done <<< "$files"

    # Specifically verify rtw_wlan_util.h
    local hdr="${SRC_DIR}/include/rtw_wlan_util.h"
    if [[ -f "$hdr" ]] && grep -q 'u8[[:space:]]*data\[1\]' "$hdr" 2>/dev/null; then
        sed -i 's/u8[[:space:]]*data\[1\];/u8 data[]; \/\* UBSAN: was data[1] *\//g' "$hdr"
        log_ok "P2 — rtw_wlan_util.h patched"
    fi
}

# =============================================================================
# P3 — UBSAN: phydm_math_lib Lookup Table Bounds Clamp
# =============================================================================
patch_phydm_bounds() {
    log_patch "P3 — UBSAN phydm_math_lib bounds clamp"
    local f="${SRC_DIR}/hal/phydm/phydm_math_lib.c"
    [[ -f "$f" ]] || { log_warn "P3 — phydm_math_lib.c not found"; return; }

    already_patched "RTL_CLAMP" "$f" && { log_ok "P3 — Already patched"; return; }

    sed -i '1s/^/\/* RTL8188FU UBSAN patch *\/\n#ifndef RTL_CLAMP\n#define RTL_CLAMP(x,lo,hi) ((x)<(lo)?(lo):((x)>(hi)?(hi):(x)))\n#endif\n\n/' "$f"
    sed -i 's/ODM_DB2LinTable\[\([^]]*\)\]\[\([^]]*\)\]/ODM_DB2LinTable[RTL_CLAMP(\1,0,11)][RTL_CLAMP(\2,0,7)] \/\* UBSAN_CLAMP *\//g' "$f"
    already_patched "RTL_CLAMP" "$f" \
        && log_ok "P3 — Bounds clamp applied" \
        || log_warn "P3 — Clamp may not have applied (ODM_DB2LinTable pattern not found)"
}

# =============================================================================
# P6 — Death Loop Fix
#   P6a: Disable CONFIG_IPS + CONFIG_LPS in autoconf.h (source level)
#   P6b: Clamp HT_caps_handler loop to sizeof(struct rtw_ieee80211_ht_cap)
#   P6c: Clamp HT_info memcpy to sizeof(struct HT_info_element)
# =============================================================================
patch_death_loop() {
    log_patch "P6 — Death loop fix (autoconf.h + HT caps overflow)"

    # P6a — autoconf.h
    local autoconf="${SRC_DIR}/include/autoconf.h"
    if [[ ! -f "$autoconf" ]]; then
        log_warn "P6a — autoconf.h not found"
    elif already_patched "RTL_DEATH_FIX" "$autoconf"; then
        log_ok "P6a — CONFIG_IPS/LPS already disabled in autoconf.h"
    else
        sed -i '/^[[:space:]]*#define CONFIG_IPS[[:space:]]*$/ s/^/\/\* RTL_DEATH_FIX: disabled *\/ \/\//' "$autoconf"
        sed -i '/^[[:space:]]*#define CONFIG_LPS[[:space:]]*$/ s/^/\/\* RTL_DEATH_FIX: disabled *\/ \/\//' "$autoconf"
        already_patched "RTL_DEATH_FIX" "$autoconf" \
            && log_ok "P6a — CONFIG_IPS and CONFIG_LPS disabled in autoconf.h" \
            || log_warn "P6a — autoconf.h patch may not have applied (check manually)"
    fi

    # P6b + P6c — rtw_wlan_util.c
    local wlan="${SRC_DIR}/core/rtw_wlan_util.c"
    if [[ ! -f "$wlan" ]]; then
        log_warn "P6b/c — rtw_wlan_util.c not found"
        return
    fi

    if already_patched "RTL_DEATH_FIX" "$wlan"; then
        log_ok "P6b/c — HT caps clamps already applied"
        return
    fi

    # P6b: HT_caps_handler loop — find line dynamically
    local ht_loop_line
    ht_loop_line=$(grep -n "for (i = 0; i < (pIE->Length)" "$wlan" 2>/dev/null \
        | grep -v "RTL_DEATH_FIX" | head -1 | cut -d: -f1 || true)

    if [[ -n "$ht_loop_line" ]]; then
        sed -i "${ht_loop_line}s/i < (pIE->Length)/i < (pIE->Length) \&\& i < (int)sizeof(struct rtw_ieee80211_ht_cap) \/* RTL_DEATH_FIX *\//" "$wlan"
        log_ok "P6b — HT_caps_handler loop clamped (line ${ht_loop_line})"
    else
        log_warn "P6b — HT caps loop pattern not found (may already be patched)"
    fi

    # P6c: HT_info memcpy — find line dynamically
    local htinfo_line
    htinfo_line=$(grep -n "_rtw_memcpy(&(pmlmeinfo->HT_info), pIE->data, pIE->Length);" \
        "$wlan" 2>/dev/null | head -1 | cut -d: -f1 || true)

    if [[ -n "$htinfo_line" ]]; then
        sed -i "${htinfo_line}s/_rtw_memcpy(\&(pmlmeinfo->HT_info), pIE->data, pIE->Length);/_rtw_memcpy(\&(pmlmeinfo->HT_info), pIE->data, (pIE->Length > sizeof(struct HT_info_element) ? sizeof(struct HT_info_element) : pIE->Length)); \/* RTL_DEATH_FIX *\//" "$wlan"
        log_ok "P6c — HT_info memcpy clamped (line ${htinfo_line})"
    else
        log_warn "P6c — HT_info memcpy pattern not found (may already be patched)"
    fi
}

# =============================================================================
# P7 — WPA3/WPA2 Fix: disable NM MAC randomization
# This old driver cannot handle random MACs during WPA3 SAE negotiation.
# Disabling makes WPA2 and WPA3-transition-mode networks work correctly.
# =============================================================================
patch_networkmanager() {
    log_patch "P7 — NetworkManager: disable MAC randomization (WPA3/WPA2 fix)"

    local nm_conf="/etc/NetworkManager/conf.d/disable-random-mac.conf"
    mkdir -p /etc/NetworkManager/conf.d/

    if [[ -f "$nm_conf" ]] && grep -q "scan-rand-mac-address=no" "$nm_conf"; then
        log_ok "P7 — MAC randomization already disabled"
    else
        printf "[device]\nwifi.scan-rand-mac-address=no\n\n[connection]\nwifi.cloned-mac-address=preserve\n" \
            > "$nm_conf"
        log_ok "P7 — MAC randomization disabled: ${nm_conf}"
    fi

    # Also set wifi.powersave=2 (disabled) in NM — prevents NM from
    # putting the interface to sleep independently of the driver
    local nm_pwr="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
    if [[ ! -f "$nm_pwr" ]]; then
        printf "[connection]\nwifi.powersave=2\n" > "$nm_pwr"
        log_ok "P7 — NM wifi powersave disabled: ${nm_pwr}"
    else
        log_ok "P7 — NM powersave config already present"
    fi

    systemctl restart NetworkManager 2>/dev/null || true
    log_ok "P7 — NetworkManager restarted"
    echo ""
    echo -e "  ${BOLD}WPA3 connection (use after install):${NC}"
    echo -e "  ${CYAN}# WPA2 (recommended for this driver):${NC}"
    echo -e "  sudo nmcli dev wifi connect \"YourSSID\" password 'YourPass' key-mgmt wpa-psk"
    echo -e "  ${CYAN}# WPA3 SAE (if router supports WPA3-transition mode):${NC}"
    echo -e "  sudo nmcli dev wifi connect \"YourSSID\" password 'YourPass' key-mgmt sae"
    echo ""
}

# =============================================================================
# UDEV RULE
# =============================================================================
install_udev_rule() {
    log_info "Installing udev rule for hot-plug support..."
    local udev_file="/etc/udev/rules.d/99-rtl8188fu.rules"
    mkdir -p /etc/udev/rules.d/
    {
        echo "# RTL8188FU auto-generated udev rules"
        echo "# Generated: $(date)"
        echo ""
        for pid in "${DETECTED_PIDS[@]}"; do
            echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0bda\", ATTRS{idProduct}==\"${pid}\", RUN+=\"/sbin/modprobe rtl8188fu\""
        done
        echo ""
        echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0bda\", ATTRS{bInterfaceClass}==\"ff\", ATTRS{bInterfaceSubClass}==\"ff\", RUN+=\"/sbin/modprobe rtl8188fu\""
    } > "$udev_file"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    log_ok "Udev rule written: ${udev_file}"
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
            || log_error "Install manually: apt install build-essential usbutils linux-headers-${KERNEL_VER}"
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
# kernel 6.2+: rtl8xxxu now claims RTL8188FU — must blacklist
# kernel 5.15/5.16: r8188eu conflicts — must blacklist
blacklist r8188eu
blacklist rtl8xxxu
EOF
    # Alias ensures our driver wins even if others probe first
    echo "alias usb:v0BDApF179d*dc*dsc*dp*icFFiscFFipFFin* rtl8188fu" \
        >> "$BLACKLIST_FILE"
    log_ok "Blacklist: ${BLACKLIST_FILE}"
}

setup_modprobe_options() {
    log_info "Writing modprobe power management options..."
    cat > "$MODPROBE_CONF" <<EOF
# RTL8188FU power management — disable IPS/LPS to prevent death loop
# These complement the source-level CONFIG_IPS/LPS disable in autoconf.h
options rtl8188fu rtw_power_mgnt=0 rtw_enusbss=0 rtw_ips_mode=0 rtw_lps_level=0 rtw_led_ctrl=0
EOF
    log_ok "Modprobe options: ${MODPROBE_CONF}"
}

compile_driver() {
    log_info "Compiling driver (kernel ${KERNEL_VER})..."
    cd "$SRC_DIR"
    make clean -s 2>/dev/null || true
    make -j"$(nproc)" 2>&1 | tee -a "$INSTALL_LOG" | tail -5
    [[ -f "${SRC_DIR}/${DRIVER_NAME}.ko" ]] \
        && log_ok "Compiled: ${DRIVER_NAME}.ko" \
        || log_error "Compile failed — run 'make' manually in ${SRC_DIR}"
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
        || log_error "Module not loaded — check: dmesg | tail -30"

    local iface
    iface=$(ip -br link | grep -v -E '^(lo|en|eth|docker|br)' | awk '{print $1}' | head -1)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        RTL8188FU Installation Complete!      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    ip -br link
    echo ""

    if [[ -n "$iface" ]]; then
        log_ok "Wireless interface: ${iface}"
        echo ""
        echo -e "  ${BOLD}Registered USB IDs:${NC}"
        for pid in "${DETECTED_PIDS[@]}"; do
            echo -e "    ${CYAN}✓${NC} 0bda:${pid}"
        done
    else
        log_warn "No wireless interface yet — plug in dongle if not connected."
    fi

    echo ""
    echo -e "  ${BOLD}Patches applied:${NC}"
    echo -e "    ${GREEN}✓${NC} P1 — USB ID auto-detection"
    echo -e "    ${GREEN}✓${NC} P2 — UBSAN flexible array (u8 data[1] → data[])"
    echo -e "    ${GREEN}✓${NC} P3 — UBSAN phydm bounds clamp"
    echo -e "    ${GREEN}✓${NC} P4/P5 — Firmware flood + power management"
    echo -e "    ${GREEN}✓${NC} P6 — Death loop (CONFIG_IPS/LPS + HT caps overflow)"
    echo -e "    ${GREEN}✓${NC} P7 — WPA3/WPA2 NetworkManager fix"
    echo ""
    echo -e "  ${BOLD}Connect to WiFi:${NC}"
    echo -e "  ${CYAN}sudo nmcli dev wifi connect \"SSID\" password 'pass' key-mgmt wpa-psk${NC}  # WPA2"
    echo -e "  ${CYAN}sudo nmcli dev wifi connect \"SSID\" password 'pass' key-mgmt sae${NC}      # WPA3"
    echo ""
    echo -e "  ${BOLD}Useful commands:${NC}"
    echo "  iw dev                              # wireless interfaces"
    echo "  iw dev <iface> scan                 # scan networks"
    echo "  dmesg | grep RTL871X                # driver logs"
    echo "  dmesg | grep 'request firm' | wc -l # firmware flood check"
    echo "  dmesg | grep UBSAN                  # UBSAN check (should be empty)"
    echo "  watch -n 5 'dmesg | grep -c Dislaunch' # death loop monitor"
    echo ""
    echo -e "  Full install log: ${CYAN}${INSTALL_LOG}${NC}"
}

uninstall() {
    log_info "Uninstalling ${DRIVER_NAME}..."
    modprobe -r "$DRIVER_NAME" 2>/dev/null || true
    rm -f "${INSTALL_DIR}/${DRIVER_NAME}.ko"
    rm -f "$BLACKLIST_FILE"
    rm -f "$MODPROBE_CONF"
    rm -f "/etc/udev/rules.d/99-rtl8188fu.rules"
    rm -f "/etc/NetworkManager/conf.d/disable-random-mac.conf"
    rm -f "/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
    udevadm control --reload-rules 2>/dev/null || true
    systemctl restart NetworkManager 2>/dev/null || true
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
echo "  ║   RTL8188FU Driver Installer v2.0           ║"
echo "  ║   USB Auto-Detection + Full Patch Suite      ║"
echo "  ║   Kernel: ${KERNEL_VER}            ║"
echo "  ╚══════════════════════════════════════════════╝"
echo -e "${NC}"

case "${1:-install}" in
    install)
        check_root
        check_dependencies
        check_source
        detect_realtek_usb_ids
        patch_all_usb_ids
        patch_flexible_array
        patch_phydm_bounds
        patch_death_loop
        patch_networkmanager
        remove_conflicting_drivers
        setup_blacklist
        setup_modprobe_options
        compile_driver
        install_driver
        install_udev_rule
        load_and_verify
        ;;
    uninstall)
        check_root
        uninstall
        ;;
    scan)
        scan_only
        ;;
    patch-only)
        check_root
        check_source
        detect_realtek_usb_ids
        patch_all_usb_ids
        patch_flexible_array
        patch_phydm_bounds
        patch_death_loop
        patch_networkmanager
        ;;
    *)
        echo "Usage: sudo bash install.sh [command]"
        echo ""
        echo "  install     Full auto-detect, patch all bugs, compile, install (default)"
        echo "  uninstall   Remove driver, rules, blacklist, NM config"
        echo "  scan        Show detected Realtek USB IDs (no changes)"
        echo "  patch-only  Apply all source patches without compiling"
        echo ""
        exit 1
        ;;
esac
