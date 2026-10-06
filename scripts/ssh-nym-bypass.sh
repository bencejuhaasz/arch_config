#!/usr/bin/env bash
# Bypass the NymVPN tunnel for inbound SSH (replies go out the LAN interface).
#
# nym-vpnd sets up:   "not from all fwmark 0x14d lookup 333"   (routing)
#   -> packets WITHOUT that fwmark use table 333 (default via tun1);
#      packets WITH it fall through to the main table (-> LAN interface).
# and its firewall (table "inet nym") only lets non-tunnel traffic through if
#   ct mark == 0xf42   (input / output / forward chains accept it).
# So we need BOTH: ct mark = nym's firewall mark, meta mark = nym's fwmark.
# Both values are read from the live system, not hardcoded.
set -euo pipefail

TABLE="inet sshBypass"
PORT="${SSH_PORT:-22}"

usage() {
    echo "Usage: $0 {on|off|status|toggle} [port]"
    echo "  on      - bypass nym for SSH (port \$2 or \$SSH_PORT or 22)"
    echo "  off     - remove the bypass"
    echo "  status  - show current state"
    echo "  toggle  - flip current state (default if no argument given)"
    exit 1
}

is_on() { nft list table $TABLE &>/dev/null; }

# fwmark of the policy rule "not from all fwmark 0x14d lookup 333"
#
# NOTE: awk must read ALL input (no early "exit"). With "set -o pipefail", an
# awk that quits early makes the writer die of SIGPIPE and the pipeline returns
# 141, which "set -e" then turns into a silent script exit.
detect_fwmark() {
    ip rule show | awk '/not from all fwmark/ && !done {
        for (i=1; i<=NF; i++) if ($i == "fwmark") { print $(i+1); done=1; break }
    }'
}

# ct mark that nym's own output chain accepts ("ct mark 0x00000f42 accept")
detect_ctmark() {
    nft list chain inet nym output 2>/dev/null \
        | awk '$1=="ct" && $2=="mark" && $NF=="accept" && !done { print $3; done=1 }'
}

enable() {
    local port="${1:-$PORT}"

    nft list table inet nym &>/dev/null \
        || { echo "Error: nft table 'inet nym' not found - is nym connected?" >&2; exit 1; }

    local mark ctmark
    mark=$(detect_fwmark)
    [[ -n "$mark" ]]   || { echo "Error: cannot detect nym fwmark from 'ip rule show'." >&2; exit 1; }
    ctmark=$(detect_ctmark)
    [[ -n "$ctmark" ]] || { echo "Error: cannot detect nym ct mark from 'nft list chain inet nym output'." >&2; exit 1; }

    # Remove stale table from old Mullvad-app-era script if present
    nft delete table inet sshExclude 2>/dev/null || true

    # Load atomically; "add table" + "delete table" makes re-running idempotent.
    nft -f - <<EOF
add table $TABLE
delete table $TABLE
table $TABLE {
    chain pre {
        type filter hook prerouting priority mangle; policy accept;
        iifname != "tun*" tcp dport $port ct mark set $ctmark
    }
    chain out {
        type route hook output priority mangle; policy accept;
        ct mark $ctmark meta mark set $mark
    }
}
EOF

    echo "nym fwmark (routing)    : $mark"
    echo "nym ct mark (firewall)  : $ctmark"
    echo "Inbound SSH on port $port, and its replies, now bypass the tunnel."
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
