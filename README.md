# wifi-ssid

**Get your current Wi-Fi SSID on macOS — without triggering Location Services.**

A pure-bash script that infers the active Wi-Fi network name by correlating the system's known-networks plist with current DHCP/router info. No Xcode, no Swift, no Python, no third-party dependencies — just built-in macOS tools.

## Why?

Starting with macOS 10.15 (Catalina), Apple gated `CWWiFiClient.ssid()` behind Location Services (TCC). Apps and scripts that call the CoreWLAN API now trigger a location permission prompt, which is unacceptable for headless/SSH sessions, automation, and privacy-conscious workflows.

This script sidesteps TCC entirely by reading data that **doesn't** require location authorization:
- The system known-networks plist (`/Library/Preferences/com.apple.wifi.known-networks.plist`)
- DHCP lease info via `ipconfig`
- Hardware registry via `ioreg` (fallback)

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                         wifi.sh                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐     ┌───────────────────┐                     │
│  │  Preflight   │     │   Arg Parsing     │                     │
│  │  ─────────── │     │   ───────────     │                     │
│  │  macOS? ─────┼─No──┼─► exit 11         │                     │
│  │  root?  ─────┼─No──┼─► exit 10         │                     │
│  │  plist? ─────┼─No──┼─► exit 5          │                     │
│  └──────┬───────┘     └───────────────────┘                     │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────┐                           │
│  │  Step 1: Detect Wi-Fi Interface  │                           │
│  │  ────────────────────────────────│                           │
│  │  networksetup -listallhardwareports                          │
│  │  (or use -i flag override)       │                           │
│  └──────┬───────────────────────────┘                           │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────┐                           │
│  │  Step 2: Get Network Environment │                           │
│  │  ────────────────────────────────│                           │
│  │  ipconfig getoption <iface>      │                           │
│  │    → router IP                   │                           │
│  │    → DHCP server IP              │                           │
│  │  (NOT gated by TCC/Location)     │                           │
│  └──────┬───────────────────────────┘                           │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Step 3: Score Known Networks                            │   │
│  │  ────────────────────────────────────────────────────     │   │
│  │  plutil -convert xml1  (binary plist → XML)              │   │
│  │                                                          │   │
│  │  For each wifi.network.ssid.<NAME> entry:                │   │
│  │    ├── IPv4NetworkSignature contains router IP?  +70     │   │
│  │    ├── IPv4NetworkSignature contains DHCP server? +85    │   │
│  │    ├── Both match?                                +90    │   │
│  │    ├── DHCPServerID (base64→hex) matches?         +85    │   │
│  │    └── Tie-break by most recent timestamp                │   │
│  │                                                          │   │
│  │  Highest-scoring network wins                            │   │
│  └──────┬───────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────┐                           │
│  │  Step 4: Fallback (if needed)    │                           │
│  │  ────────────────────────────────│                           │
│  │  ioreg -l -n AirPortDriver      │                           │
│  │    → IO80211SSID                 │                           │
│  │  (works when TCC not blocking)   │                           │
│  └──────┬───────────────────────────┘                           │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────────────────────────┐                           │
│  │  Output                          │                           │
│  │  ────────────────────────────────│                           │
│  │  --json    → JSON object         │                           │
│  │  --verbose → key-value table     │                           │
│  │  default   → plain SSID string   │                           │
│  └──────────────────────────────────┘                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Requirements

- **macOS 11+** (Big Sur, Monterey, Ventura, Sonoma, Sequoia, Tahoe)
- **Root access** (`sudo`) — needed to read the system known-networks plist
- **No third-party tools** — uses only `plutil`, `ipconfig`, `ioreg`, `networksetup`, `ifconfig`, `sw_vers`, `sed`, `grep`, `awk`, `base64`, `xxd`

## Installation

```bash
# Clone
git clone https://github.com/yourusername/wifi-ssid.git
cd wifi-ssid

# Make executable
chmod +x wifi.sh
```

## Usage

```bash
# Basic — print current SSID
sudo ./wifi.sh

# Detailed info (SSID, signal strength, channel, etc.)
sudo ./wifi.sh --verbose

# JSON output (pipe-friendly)
sudo ./wifi.sh --json

# List all known/remembered Wi-Fi networks
sudo ./wifi.sh --all

# Known networks as JSON
sudo ./wifi.sh --all --json

# Use a specific interface
sudo ./wifi.sh -i en1

# Help
./wifi.sh --help

# Version
./wifi.sh --version
```

### Options

| Flag | Long | Description |
|------|------|-------------|
| `-i` | `--interface IFACE` | Specify Wi-Fi interface (default: auto-detect) |
| `-v` | `--verbose` | Detailed connection info (RSSI, channel, security) |
| `-j` | `--json` | Output as JSON |
| `-a` | `--all` | List all known networks from system plist |
| `-h` | `--help` | Show help (works without root) |
| `-V` | `--version` | Show version (works without root) |

### Example Output

**Default:**
```
MyHomeNetwork
```

**Verbose (`-v`):**
```
Interface:       en0
SSID:            MyHomeNetwork
Router IP:       192.168.1.1
DHCP Server:     192.168.1.1
RSSI:            -42
Noise:           -90
Channel:         149
Security:        wpa2-psk
Tx Rate:         867
```

**JSON (`-j`):**
```json
{
  "interface": "en0",
  "ssid": "MyHomeNetwork",
  "router_ip": "192.168.1.1",
  "dhcp_server": "192.168.1.1",
  "rssi": "-42",
  "noise": "-90",
  "channel": "149",
  "security": "wpa2-psk",
  "tx_rate": "867"
}
```

**All networks (`-a`):**
```
Known Wi-Fi Networks:
  1. HomeNetwork
  2. OfficeWiFi
  3. CoffeeShop5G
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | Success |
| `2`  | Usage error (bad arguments) |
| `3`  | Not connected to Wi-Fi |
| `4`  | SSID not found in known-networks plist |
| `5`  | Plist file unreadable |
| `10` | Not running as root |
| `11` | Not running on macOS |
| `12` | Invalid network interface |

## Scoring Algorithm

The script uses a confidence-scoring system to match the current network environment against entries in the known-networks plist:

| Match | Score |
|-------|-------|
| Router IP found in `IPv4NetworkSignature` | 70 |
| DHCP server found in `IPv4NetworkSignature` | 85 |
| Both router IP and DHCP server match | 90 |
| `DHCPServerID` raw bytes match | 85 (or 90 if combined with router) |

When multiple networks tie on score, the one with the most recent association timestamp wins (`LastAssociatedAt`, `JoinedBySystemAt`, etc.).

## Notes

- **Signal info is best-effort**: The `airport` utility was deprecated in macOS 14.4 (Sonoma). On newer systems, RSSI/channel/security may show as `N/A`.
- **VPN awareness**: The script warns (but does not fail) when VPN tunnels (`utun`) are detected, since the router IP may not match the Wi-Fi gateway.
- **`--help` and `--version` work without root** — all other operations require `sudo`.

## License

[MIT](LICENSE)
