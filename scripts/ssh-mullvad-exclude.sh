#!/usr/bin/env bash
# Toggle an nftables rule that exempts SSH from Mullvad's tunnel/firewall,
# using Mullvad's own split-tunnel marks (see Mullvad's "Split tunneling
# with Linux (advanced)" guide for what these marks mean).
set -euo pipefail

CT_MARK=0x00000f41
PKT_MARK=0x6d6f6c65
TABLE="inet sshExclude"
PORT="${SSH_PORT:-22}"

usage() {
    echo "Usage: $0 {on|off|status|toggle} [port]"
    echo "  on      - exclude SSH (port \$2 or \$SSH_PORT or 22) from the Mullvad tunnel"
    echo "  off     - remove the exclusion"
    echo "  status  - show whether the exclusion is active"
    echo "  toggle  - flip current state (default if no argument given)"
    exit 1
}

is_on() {
    nft list table $TABLE &>/dev/null
}

enable() {
    local port="${1:-$PORT}"
    nft -f - <<EOF
table $TABLE {
    chain incoming {
        type filter hook input priority -1; policy accept;
        tcp dport $port ct mark set $CT_MARK meta mark set $PKT_MARK
    }
    chain outgoing {
        type route hook output priority -1; policy accept;
        tcp sport $port ct mark set $CT_MARK meta mark set $PKT_MARK
    }
}
EOF
    echo "SSH (port $port) is now excluded from the Mullvad tunnel."
}

disable() {
    nft delete table $TABLE 2>/dev/null || true
    echo "SSH exclusion removed; SSH now follows Mullvad's normal rules again."
}

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo $0 ...)." >&2; exit 1; }

cmd="${1:-toggle}"
port_arg="${2:-$PORT}"

case "$cmd" in
    on) enable "$port_arg" ;;
    off) disable ;;
    status)
        if is_on; then
            echo "ON:"
            nft list table $TABLE
        else
            echo "OFF"
        fi
        ;;
    toggle)
        if is_on; then disable; else enable "$port_arg"; fi
        ;;
    *) usage ;;
esac
