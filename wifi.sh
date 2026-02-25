#!/bin/bash
# ============================================================================
# wifi.sh — Infer Wi-Fi SSID on macOS WITHOUT Location Services (TCC)
# ============================================================================
# Pure bash, zero third-party dependencies.
# Uses only built-in macOS tools: plutil, ipconfig, ioreg, networksetup,
# ifconfig, sw_vers, sed, grep, awk, base64, xxd
#
# How it works:
#   1. Auto-detects the Wi-Fi interface (or accepts one via -i)
#   2. Reads /Library/Preferences/com.apple.wifi.known-networks.plist
#   3. Gets current DHCP server + router IP (not TCC-gated)
#   4. Converts plist to XML, scores each known network by matching
#      IPv4NetworkSignature and DHCPServerID against current environment
#   5. Falls back to ioreg IO80211SSID if plist matching fails
#
# Compatible: macOS 11+ (Big Sur through Tahoe)
# ============================================================================

VERSION="2.0.0"

# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
readonly EX_OK=0
readonly EX_USAGE=2
readonly EX_NOT_CONNECTED=3
readonly EX_SSID_NOT_FOUND=4
readonly EX_PLIST_UNREADABLE=5
readonly EX_NOT_ROOT=10
readonly EX_NOT_MACOS=11
readonly EX_BAD_INTERFACE=12

# ---------------------------------------------------------------------------
# Global defaults
# ---------------------------------------------------------------------------
VERBOSE=0
JSON_OUTPUT=0
LIST_ALL=0
IFACE=""

readonly PLIST="/Library/Preferences/com.apple.wifi.known-networks.plist"
readonly AIRPORT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
die() {
    local code="$1"; shift
    printf 'Error: %s\n' "$*" >&2
    exit "$code"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

log_verbose() {
    (( VERBOSE )) && printf '%s\n' "$*" >&2
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Validation functions
# ---------------------------------------------------------------------------
check_macos() {
    [[ "$(uname)" == "Darwin" ]] \
        || die $EX_NOT_MACOS "This script requires macOS (detected: $(uname))."

    local macos_ver
    macos_ver="$(sw_vers -productVersion 2>/dev/null || echo "")"
    if [[ -n "$macos_ver" ]]; then
        local major="${macos_ver%%.*}"
        if (( major < 11 )); then
            warn "macOS 11+ recommended (detected: $macos_ver). Results may be unreliable."
        fi
    fi
}

check_root() {
    (( $(id -u) == 0 )) \
        || die $EX_NOT_ROOT "Root privileges required. Run with: sudo $0"
}

validate_interface() {
    local iface="$1"
    if ! ifconfig "$iface" >/dev/null 2>&1; then
        die $EX_BAD_INTERFACE "Interface '$iface' not found."
    fi
    # Warn if the interface doesn't look like Wi-Fi
    if ! networksetup -listallhardwareports 2>/dev/null \
            | grep -A1 'Wi-Fi' | grep -q "$iface"; then
        warn "Interface '$iface' may not be a Wi-Fi adapter."
    fi
}

# ---------------------------------------------------------------------------
# Data functions
# ---------------------------------------------------------------------------
detect_wifi_interface() {
    local iface
    iface="$(networksetup -listallhardwareports 2>/dev/null \
        | awk '/Wi-Fi/{getline; print $2}')"
    if [[ -z "$iface" ]]; then
        iface="en0"
        warn "Could not auto-detect Wi-Fi interface; falling back to en0."
    fi
    printf '%s' "$iface"
}

# Convert an IPv4 address to 0x-prefixed hex (e.g. 10.58.64.21 -> 0x0a3a4015)
ip_to_hex() {
    local ip="$1" hex="0x"
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $ip
    for octet in "$@"; do
        hex+=$(printf "%02x" "$octet")
    done
    printf '%s' "$hex"
}

get_router_ip() {
    ipconfig getoption "$1" router 2>/dev/null
}

get_dhcp_server() {
    ipconfig getoption "$1" server_identifier 2>/dev/null
}

# ---------------------------------------------------------------------------
# Plist scoring engine
# ---------------------------------------------------------------------------
# Converts the known-networks plist to XML, then walks it line-by-line,
# tracking which SSID block we're in. Each BSS entry is scored by how well
# its IPv4NetworkSignature / DHCPServerID match the current network env.
# Ties are broken by the most recent timestamp.
# ---------------------------------------------------------------------------
find_ssid_by_scoring() {
    local router_ip="$1" dhcp_server="$2"

    local tmpxml
    tmpxml=$(mktemp /tmp/known-networks.XXXXXX.xml)
    trap 'rm -f "$tmpxml"' RETURN

    plutil -convert xml1 -o "$tmpxml" "$PLIST" 2>/dev/null
    if [[ ! -s "$tmpxml" ]]; then
        die $EX_PLIST_UNREADABLE "Failed to convert known-networks plist to XML."
    fi

    local dhcp_hex=""
    [[ -n "$dhcp_server" ]] && dhcp_hex="$(ip_to_hex "$dhcp_server")"

    local best_ssid="" best_score=0 best_ts="0"
    local cur_ssid="" cur_score=0 cur_ts="0"
    local prev_key=""

    while IFS= read -r line; do

        # ---- Top-level network key: wifi.network.ssid.<NAME> ----
        case "$line" in
            *'<key>wifi.network.ssid.'*'</key>'*)
                # Evaluate the previous block
                if [[ -n "$cur_ssid" && "$cur_score" -gt 0 ]]; then
                    if (( cur_score > best_score )) \
                       || { (( cur_score == best_score )) && [[ "$cur_ts" > "$best_ts" ]]; }; then
                        best_score=$cur_score; best_ssid="$cur_ssid"; best_ts="$cur_ts"
                    fi
                fi
                cur_ssid="$(sed 's/.*<key>wifi\.network\.ssid\.\(.*\)<\/key>.*/\1/' <<< "$line")"
                cur_score=0; cur_ts="0"; prev_key=""
                continue ;;
        esac

        # ---- Track <key> elements ----
        case "$line" in
            *'<key>'*'</key>'*)
                prev_key="$(sed 's/.*<key>\([^<]*\)<\/key>.*/\1/' <<< "$line")"
                continue ;;
        esac

        # ---- IPv4NetworkSignature ----
        if [[ "$prev_key" == "IPv4NetworkSignature" ]]; then
            case "$line" in
                *'<string>'*'</string>'*)
                    local sig
                    sig="$(sed 's/.*<string>\([^<]*\)<\/string>.*/\1/' <<< "$line")"
                    local s=0
                    [[ -n "$router_ip"   && "$sig" == *"$router_ip"*   ]] && s=70
                    [[ -n "$dhcp_server" && "$sig" == *"$dhcp_server"* ]] && \
                        { (( s >= 70 )) && s=90 || s=85; }
                    (( s > cur_score )) && cur_score=$s
                    prev_key=""; continue ;;
            esac
        fi

        # ---- DHCPServerID (base64 encoded raw bytes) ----
        if [[ "$prev_key" == "DHCPServerID" && -n "$dhcp_hex" ]]; then
            case "$line" in
                *'<data>'*'</data>'*)
                    local raw_b64 decoded_hex
                    raw_b64="$(sed 's/.*<data>\([^<]*\)<\/data>.*/\1/' <<< "$line")"
                    decoded_hex="$(printf '%s' "$raw_b64" | base64 -d 2>/dev/null \
                        | xxd -p 2>/dev/null || echo "")"
                    if [[ -n "$decoded_hex" && "0x${decoded_hex}" == "$dhcp_hex" ]]; then
                        if (( cur_score < 85 )); then
                            (( cur_score >= 70 )) && cur_score=90 || cur_score=85
                        fi
                    fi
                    prev_key=""; continue ;;
            esac
        fi

        # ---- Timestamps for tie-breaking ----
        case "$prev_key" in
            LastAssociatedAt|JoinedBySystemAt|JoinedByUserAt|AddedAt)
                case "$line" in
                    *'<date>'*'</date>'*)
                        local ts
                        ts="$(sed 's/.*<date>\([^<]*\)<\/date>.*/\1/' <<< "$line")"
                        [[ -n "$ts" && "$ts" > "$cur_ts" ]] && cur_ts="$ts"
                        prev_key=""; continue ;;
                esac ;;
        esac

    done < "$tmpxml"

    # Evaluate the final block
    if [[ -n "$cur_ssid" && "$cur_score" -gt 0 ]]; then
        if (( cur_score > best_score )) \
           || { (( cur_score == best_score )) && [[ "$cur_ts" > "$best_ts" ]]; }; then
            best_ssid="$cur_ssid"
        fi
    fi

    [[ -n "$best_ssid" ]] && printf '%s' "$best_ssid"
}

# ---------------------------------------------------------------------------
# ioreg fallback (works when TCC is not blocking)
# ---------------------------------------------------------------------------
fallback_ioreg_ssid() {
    local ssid
    ssid="$(ioreg -l -n AirPortDriver 2>/dev/null \
        | awk -F'"' '/IO80211SSID/{print $4}')"
    [[ -n "$ssid" && "$ssid" != "<redacted>" ]] && printf '%s' "$ssid"
}

# ---------------------------------------------------------------------------
# List all known networks from the plist
# ---------------------------------------------------------------------------
list_all_networks() {
    local tmpxml
    tmpxml=$(mktemp /tmp/known-networks.XXXXXX.xml)
    trap 'rm -f "$tmpxml"' RETURN

    plutil -convert xml1 -o "$tmpxml" "$PLIST" 2>/dev/null
    [[ ! -s "$tmpxml" ]] && return 1

    grep '<key>wifi\.network\.ssid\.' "$tmpxml" \
        | sed 's/.*<key>wifi\.network\.ssid\.\(.*\)<\/key>.*/\1/' \
        | sort -u
}

# ---------------------------------------------------------------------------
# Signal / connection info (best-effort via airport)
# ---------------------------------------------------------------------------
get_signal_info() {
    local rssi="N/A" noise="N/A" channel="N/A" security="N/A" tx_rate="N/A"

    if [[ -x "$AIRPORT" ]]; then
        local out
        out="$("$AIRPORT" -I 2>/dev/null || true)"
        if [[ -n "$out" ]]; then
            local v
            v="$(awk '/agrCtlRSSI/{print $2}'  <<< "$out")"; [[ -n "$v" ]] && rssi="$v"
            v="$(awk '/agrCtlNoise/{print $2}'  <<< "$out")"; [[ -n "$v" ]] && noise="$v"
            v="$(awk '/\bchannel/{print $2}'    <<< "$out")"; [[ -n "$v" ]] && channel="$v"
            v="$(awk '/link auth/{print $2}'    <<< "$out")"; [[ -n "$v" ]] && security="$v"
            v="$(awk '/lastTxRate/{print $2}'   <<< "$out")"; [[ -n "$v" ]] && tx_rate="$v"
        fi
    else
        log_verbose "airport utility not found (deprecated macOS 14.4+); signal info unavailable."
    fi

    printf '%s\n%s\n%s\n%s\n%s' "$rssi" "$noise" "$channel" "$security" "$tx_rate"
}

# ---------------------------------------------------------------------------
# Output functions
# ---------------------------------------------------------------------------
output_plain() {
    printf '%s\n' "$1"
}

output_verbose() {
    local iface="$1" ssid="$2" router_ip="$3" dhcp_server="$4"

    local sig
    sig="$(get_signal_info)"
    local rssi noise channel security tx_rate
    rssi="$(sed -n '1p' <<< "$sig")"
    noise="$(sed -n '2p' <<< "$sig")"
    channel="$(sed -n '3p' <<< "$sig")"
    security="$(sed -n '4p' <<< "$sig")"
    tx_rate="$(sed -n '5p' <<< "$sig")"

    printf '%-16s %s\n' "Interface:"   "$iface"
    printf '%-16s %s\n' "SSID:"        "$ssid"
    printf '%-16s %s\n' "Router IP:"   "${router_ip:-N/A}"
    printf '%-16s %s\n' "DHCP Server:" "${dhcp_server:-N/A}"
    printf '%-16s %s\n' "RSSI:"        "$rssi"
    printf '%-16s %s\n' "Noise:"       "$noise"
    printf '%-16s %s\n' "Channel:"     "$channel"
    printf '%-16s %s\n' "Security:"    "$security"
    printf '%-16s %s\n' "Tx Rate:"     "$tx_rate"
}

output_json() {
    local iface="$1" ssid="$2" router_ip="$3" dhcp_server="$4"

    local sig
    sig="$(get_signal_info)"
    local rssi noise channel security tx_rate
    rssi="$(sed -n '1p' <<< "$sig")"
    noise="$(sed -n '2p' <<< "$sig")"
    channel="$(sed -n '3p' <<< "$sig")"
    security="$(sed -n '4p' <<< "$sig")"
    tx_rate="$(sed -n '5p' <<< "$sig")"

    printf '{\n'
    printf '  "interface": "%s",\n'    "$(json_escape "$iface")"
    printf '  "ssid": "%s",\n'         "$(json_escape "$ssid")"
    printf '  "router_ip": "%s",\n'    "$(json_escape "${router_ip:-}")"
    printf '  "dhcp_server": "%s",\n'  "$(json_escape "${dhcp_server:-}")"
    printf '  "rssi": "%s",\n'         "$(json_escape "$rssi")"
    printf '  "noise": "%s",\n'        "$(json_escape "$noise")"
    printf '  "channel": "%s",\n'      "$(json_escape "$channel")"
    printf '  "security": "%s",\n'     "$(json_escape "$security")"
    printf '  "tx_rate": "%s"\n'       "$(json_escape "$tx_rate")"
    printf '}\n'
}

output_all_plain() {
    local networks="$1"
    printf 'Known Wi-Fi Networks:\n'
    local i=1
    while IFS= read -r ssid; do
        [[ -z "$ssid" ]] && continue
        printf '  %d. %s\n' "$i" "$ssid"
        (( i++ ))
    done <<< "$networks"
}

output_all_verbose() {
    local networks="$1"
    printf 'Known Wi-Fi Networks (from %s):\n\n' "$PLIST"
    local i=1
    while IFS= read -r ssid; do
        [[ -z "$ssid" ]] && continue
        printf '  [%d] SSID: %s\n' "$i" "$ssid"
        (( i++ ))
    done <<< "$networks"
    printf '\nTotal: %d network(s)\n' "$(( i - 1 ))"
}

output_all_json() {
    local networks="$1"
    printf '{\n  "known_networks": [\n'
    local first=1
    while IFS= read -r ssid; do
        [[ -z "$ssid" ]] && continue
        (( first )) && first=0 || printf ',\n'
        printf '    "%s"' "$(json_escape "$ssid")"
    done <<< "$networks"
    printf '\n  ]\n}\n'
}

# ---------------------------------------------------------------------------
# usage()
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
wifi.sh v${VERSION} — Infer Wi-Fi SSID on macOS without Location Services

SYNOPSIS
    sudo ./wifi.sh [OPTIONS]

DESCRIPTION
    Reads the system known-networks plist and correlates IPv4 network
    signatures with the current DHCP/router environment to identify the
    active Wi-Fi network — all without triggering a TCC Location Services
    prompt. Falls back to ioreg if plist matching fails.

OPTIONS
    -i, --interface IFACE   Use a specific Wi-Fi interface (default: auto-detect)
    -v, --verbose           Show detailed connection info (RSSI, channel, etc.)
    -j, --json              Output in JSON format
    -a, --all               List all known Wi-Fi networks from the system plist
    -h, --help              Show this help message and exit
    -V, --version           Show version and exit

EXAMPLES
    sudo ./wifi.sh                  Print current SSID
    sudo ./wifi.sh -v               Detailed info (SSID, signal, channel)
    sudo ./wifi.sh -j               JSON output
    sudo ./wifi.sh -a               List all remembered networks
    sudo ./wifi.sh -a -j            Known networks as JSON
    sudo ./wifi.sh -i en1           Use a specific interface

EXIT CODES
     0   Success
     2   Usage error (bad arguments)
     3   Not connected to Wi-Fi
     4   SSID not found in known-networks plist
     5   Plist file unreadable
    10   Not running as root
    11   Not running on macOS
    12   Invalid network interface
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing (manual while/case — works with macOS BSD getopt)
# ---------------------------------------------------------------------------
while (( $# )); do
    case "$1" in
        -i|--interface)
            [[ -z "${2:-}" ]] && die $EX_USAGE "Option $1 requires an argument."
            IFACE="$2"; shift 2 ;;
        -v|--verbose)   VERBOSE=1;     shift ;;
        -j|--json)      JSON_OUTPUT=1; shift ;;
        -a|--all)       LIST_ALL=1;    shift ;;
        -h|--help)      usage;  exit $EX_OK ;;
        -V|--version)   printf 'wifi.sh %s\n' "$VERSION"; exit $EX_OK ;;
        -*)             die $EX_USAGE "Unknown option: $1 (see --help)" ;;
        *)              die $EX_USAGE "Unexpected argument: $1 (see --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_macos
check_root

# Determine interface
if [[ -z "$IFACE" ]]; then
    IFACE="$(detect_wifi_interface)"
    log_verbose "Auto-detected Wi-Fi interface: $IFACE"
else
    validate_interface "$IFACE"
fi

# VPN detection (warning only)
if ifconfig 2>/dev/null | grep -q '^utun'; then
    warn "VPN tunnel (utun) detected; router IP may differ from Wi-Fi gateway."
fi

# Plist readability check
[[ -r "$PLIST" ]] \
    || die $EX_PLIST_UNREADABLE "Cannot read $PLIST — ensure root and macOS 11+."

# === --all mode: list known networks and exit ===
if (( LIST_ALL )); then
    networks="$(list_all_networks)" \
        || die $EX_PLIST_UNREADABLE "Failed to read known-networks plist."
    [[ -z "$networks" ]] && die $EX_SSID_NOT_FOUND "No known networks found in plist."

    if   (( JSON_OUTPUT )); then output_all_json    "$networks"
    elif (( VERBOSE ));     then output_all_verbose  "$networks"
    else                         output_all_plain    "$networks"
    fi
    exit $EX_OK
fi

# === Normal mode: find current SSID ===
router_ip="$(get_router_ip "$IFACE")"
dhcp_server="$(get_dhcp_server "$IFACE")"

if [[ -z "$router_ip" && -z "$dhcp_server" ]]; then
    die $EX_NOT_CONNECTED "Not connected to Wi-Fi on $IFACE (no router / DHCP info)."
fi
log_verbose "Router IP: ${router_ip:-<none>}  DHCP Server: ${dhcp_server:-<none>}"

# Primary: plist scoring
ssid="$(find_ssid_by_scoring "$router_ip" "$dhcp_server")"

# Fallback: ioreg
if [[ -z "$ssid" ]]; then
    log_verbose "Plist match failed; trying ioreg fallback…"
    ssid="$(fallback_ioreg_ssid)"
fi

[[ -z "$ssid" ]] \
    && die $EX_SSID_NOT_FOUND "Connected but SSID could not be determined."

# Output
if   (( JSON_OUTPUT )); then output_json    "$IFACE" "$ssid" "$router_ip" "$dhcp_server"
elif (( VERBOSE ));     then output_verbose  "$IFACE" "$ssid" "$router_ip" "$dhcp_server"
else                         output_plain    "$ssid"
fi

exit $EX_OK
