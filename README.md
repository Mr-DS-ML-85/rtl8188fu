# RTL8188FU Linux Driver — Patched

One-click compile and install for the Realtek RTL8188FU USB WiFi adapter on Linux.

Includes a patch for OEM variant USB ID `0xf149` (`0bda:f149`) which is not present in the upstream Rockchip-sourced driver — the most common reason this dongle loads its module but never creates a network interface.

---

## Supported Devices

| USB ID | Description |
|--------|-------------|
| `0bda:f179` | RTL8188FU standard |
| `0bda:f149` | RTL8188FU OEM variant (e.g. `Realtek 802.11n`) |

Check yours with:
```bash
lsusb | grep -i realtek
```

---

## Requirements

- Linux kernel with headers installed
- `build-essential` (gcc, make)
- Root / sudo access

```bash
sudo apt install build-essential linux-headers-$(uname -r)
```

---

## Quick Install

```bash
git clone https://github.com/youruser/rtl8188fu /usr/src/rtl8188fu-1.0
cd /usr/src/rtl8188fu-1.0
sudo bash install.sh
```

That's it. The script will:

1. Check and install missing build dependencies
2. Patch `usb_intf.c` to add the `0xF149` OEM USB ID (idempotent — safe to run twice)
3. Remove conflicting drivers (`r8188eu`, `rtl8xxxu`)
4. Blacklist competing drivers
5. Compile the driver against your running kernel
6. Install and load the module
7. Report the detected wireless interface

---

## Usage

```bash
sudo bash install.sh [command]
```

| Command | Description |
|---------|-------------|
| `install` | Full patch, compile, and install *(default)* |
| `uninstall` | Remove driver, module, and blacklist |
| `patch-only` | Apply USB ID patch to source without building |

---

## Verify It Works

After install, confirm the interface exists:
```bash
ip -br link          # look for wlan0 or wlxXXXX
iw dev               # wireless interface details
dmesg | grep RTL871X # driver init log
```

Expected dmesg output on success:
```
RTL871X: module init start
RTL871X: rtl8188fu v4.3.23.6_20964.20170110
usbcore: registered new interface driver rtl8188fu
RTL871X: module init ret=0
rtl8188fu 2-1.x:1.0 wlan0: renamed from wlan0
```

---

## Troubleshooting

**Module loads but no interface appears**

Your dongle's USB ID is likely not in the driver table. Check:
```bash
lsusb | grep -i realtek
# Example output: Bus 002 Device 004: ID 0bda:f149 Realtek ...
```
If it shows something other than `f179` or `f149`, open an issue with your USB ID and we'll add it.

**Competing driver takes over after reboot**

The blacklist file at `/etc/modprobe.d/blacklist-r8188eu.conf` should prevent this. If not:
```bash
sudo modprobe -r r8188eu rtl8xxxu
sudo modprobe rtl8188fu
```

**Kernel update breaks the driver**

Rerun the installer — it always compiles against the currently running kernel:
```bash
sudo bash install.sh
```

**EEPROM ID invalid warning in dmesg**

```
EEPROM ID(0xffff) is invalid!!
```
This appears during driver switching attempts and is harmless once `rtl8188fu` takes over. Ignore it if your interface comes up.

---

## What the Patches Do

### Patch 1: OEM USB ID (`0bda:f149`)

The Rockchip-sourced driver only includes USB product ID `0xF179` in its device table. The script adds the OEM variant `0xF149` — the chip is identical, only the USB product ID differs.

### Patch 2: UBSAN Bug Fixes

Fixed 6 undefined behavior bugs detected by the kernel's UBSAN (Undefined Behavior Sanitizer):

| File | Bug | Fix |
|------|-----|-----|
| `rtw_wlan_util.c` | Array-index-out-of-bounds in `HT_caps_handler` (3 instances) | Added `sizeof(HT_cap)` bounds check before indexing |
| `ioctl_cfg80211.c:5780` | Shift-out-of-bounds in `cfg80211_rtw_mgmt_frame_register` | Masked shift value with `& 0xF` |
| `ioctl_cfg80211.c:1431-1432` | Array-index-out-of-bounds in `rtw_cfg80211_set_encryption` | Added `key_len` bounds check before `memcpy` |

### Patch 3: sprintf Overlap Fix

Fixed undefined behavior in `rtw_mp.c` where `sprintf(data, "%s%x ", data, psd_data)` read and wrote the same buffer. Replaced with offset-based appending.

### Patch 4: WPA3-SAE Support — ⚠️ DOES NOT WORK (Firmware Limitation)

**WPA3-SAE is fundamentally impossible with the RTL8188FU.** This is not a driver bug — it's a hardware/firmware limitation that cannot be fixed in software.

**What was implemented (driver side works):**
- **RX descriptor fix** (`rtl8188f_rxdesc.c`): Fixed unencrypted management frames being falsely reported as decrypted (broke 802.11w/PMF).
- **SAE AKM suite** (`ioctl_cfg80211.c`): Added `WLAN_AKM_SUITE_SAE` handling.
- **External auth** (`ioctl_cfg80211.c`): Added `external_auth` cfg80211_ops callback with deferred work + `genlmsg_multicast_allns()` to deliver `NL80211_CMD_EXTERNAL_AUTH` events to wpa_supplicant.
- **MFP capability**: Set `NL80211_FEATURE_SAE` and `NL80211_EXT_FEATURE_MFP_OPTIONAL` so NetworkManager offers WPA3.

**Why it fails:**
1. Driver detects SAE, sends `NL80211_CMD_EXTERNAL_AUTH` to wpa_supplicant ✅
2. wpa_supplicant receives it, derives SAE keys, sends SAE Commit via raw frame ✅
3. AP receives commit, sends back SAE Confirm (AUTH frame) ✅
4. **RTL8188FU firmware receives the AUTH frame but handles it internally (open-system auth) and NEVER passes it to the host driver** ❌
5. wpa_supplicant never gets the SAE Confirm → 10s timeout → disconnect

**Root cause:** The RTL8188FU firmware uses **Firmware MLME** — it handles authentication internally. For SAE to work, the firmware would need **SAE offload** support (like Broadcom's `SAE_OFFLOAD` feature). Realtek discontinued RTL8188FU development in mid-2023 and no such firmware exists.

**Confirmed:** This same limitation affects other Realtek USB drivers (rtl8812au, rtl8814au). The in-kernel `rtl8xxxu` driver also lacks SAE support.

**Workaround:** Use WPA2, or use a Mediatek/Atheros-based USB adapter for WPA3.

---

## Tested On

| Kernel | Distro | Status |
|--------|--------|--------|
| 7.0.0-15-generic | Ubuntu-based | ✅ Working |

PRs welcome for other kernel/distro confirmations.

---

## License

GPL v2 — see original driver source for full license terms.
