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

## What the Patch Does

The Rockchip-sourced driver only includes USB product ID `0xF179` in its device table:

```c
// Before patch — only one ID:
{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xF179, 0xff, 0xff, 0xff), .driver_info = RTL8188F},
```

The script adds the OEM variant via `sed` (no manual editing, no syntax errors):

```c
// After patch — both IDs:
{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xF179, 0xff, 0xff, 0xff), .driver_info = RTL8188F},
{USB_DEVICE_AND_INTERFACE_INFO(USB_VENDER_ID_REALTEK, 0xF149, 0xff, 0xff, 0xff), .driver_info = RTL8188F},
```

The chip is identical — only the USB product ID registered by the OEM differs.

---

## Tested On

| Kernel | Distro | Status |
|--------|--------|--------|
| 7.0.0-15-generic | Ubuntu-based | ✅ Working |

PRs welcome for other kernel/distro confirmations.

---

## License

GPL v2 — see original driver source for full license terms.
