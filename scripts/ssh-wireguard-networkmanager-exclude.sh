#!/usr/bin/env bash
# Bypass WireGuard (NetworkManager-managed) for inbound SSH via DNAT.
#
# NetworkManager sets up:  "not from all fwmark 0xXXXX lookup <wg-table>"
# Traffic without that mark goes through WireGuard; with it, falls through to
# the main table (→ wlp3s0 → router). We tag incoming SSH connections with
# that mark so replies go back out the LAN interface instead of the tunnel.
set -euo pipefail

TABLE="inet sshBypass"
PORT="${SSH_PORT:-22}"

usage() {
    echo "Usage: $0 {on|off|status|toggle} [port]"
    echo "  on      - bypass WireGuard for SSH (port \$2 or \$SSH_PORT or 22)"
    echo "  off     - remove the bypass"
    echo "  status  - show current state"
    echo "  toggle  - flip current state (default if no argument given)"
    exit 1
}

is_on() { nft list table $TABLE &>/dev/null; }

detect_wg_if() {
    ip link show type wireguard 2>/dev/null \
        | awk -F': ' '/^[0-9]+:/{gsub(/@.*/, "", $2); print $2; exit}'
}

# Extract the bypass fwmark from NM's WireGuard policy rule:
#   "not from all fwmark 0xXXXX lookup <table>"
detect_nm_mark() {
    ip rule show | awk '/not from all fwmark/{
        for (i=1; i<=NF; i++) if ($i == "fwmark") { print $(i+1); exit }
    }'
}

enable() {
    local port="${1:-$PORT}"

    local wg
    wg=$(detect_wg_if)
    [[ -n "$wg" ]] || { echo "Error: no WireGuard interface found – is the VPN up?" >&2; exit 1; }

    local mark
    mark=$(detect_nm_mark)
    [[ -n "$mark" ]] || { echo "Error: cannot detect NM WireGuard bypass mark from 'ip rule show'." >&2; exit 1; }

    # Remove stale table from old Mullvad-app-era script if present
    nft delete table inet sshExclude 2>/dev/null || true

    nft -f - <<EOF
table $TABLE {
    chain pre {
        type filter hook prerouting priority mangle; policy accept;
        iifname != "$wg" tcp dport $port ct mark set $mark
    }
    chain out {
        type route hook output priority mangle; policy accept;
        ct mark $mark meta mark set $mark
    }
}
EOF

    echo "WireGuard interface : $wg"
    echo "NM bypass mark      : $mark"
    echo "SSH port $port replies will now route via LAN (not WireGuard)."
}

disable() {
    nft delete table $TABLE 2>/dev/null || true
    nft delete table inet sshExclude 2>/dev/null || true
    echo "SSH bypass removed."
}

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0 ...)." >&2; exit 1; }

cmd="${1:-toggle}"
port_arg="${2:-$PORT}"

case "$cmd" in
    on)     enable "$port_arg" ;;
    off)    disable ;;
    status)
        if is_on; then
            echo "ON:"
            nft list table $TABLE
        else
            echo "OFF"
        fi
        ;;
    toggle) if is_on; then disable; else enable "$port_arg"; fi ;;
    *) usage ;;
esac
