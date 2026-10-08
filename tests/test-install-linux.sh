#!/usr/bin/env bash
# End-to-end test for install.sh on Linux (Ubuntu).
#
# Runs inside a Docker container with systemd, hits the REAL GitHub
# releases to download binaries, feeds passphrase via stdin, and
# asserts on every expected outcome.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
TEST_PASSPHRASE="correct-horse-battery-staple-e2e-test"

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc"
        FAIL=$((FAIL + 1))
    fi
}

[[ "$(uname -s)" == "Linux" ]] || { echo "This test is intended for Linux only."; exit 1; }
[[ -f "$INSTALL_SCRIPT" ]] || { echo "install.sh not found at $INSTALL_SCRIPT"; exit 1; }

# Isolated fake HOME so we don't contaminate the real user's files
export TEST_HOME
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
export MONETARIUM_HOME="$TEST_HOME/.monetarium"

echo "== Running install.sh (real GitHub releases) =="
OUTPUT_FILE="$TEST_HOME/install-output.log"

# Feed passphrase (prompt + confirm) + wallet --create answers:
#   yes  → use passphrase from config
#   ''   → no additional encryption (Enter)
#   ''   → no existing seed (Enter)
#   OK   → confirm seed backup
#   ''   → no additional account (Enter)
#
# Run with bash -c "$(cat install.sh)" to simulate the curl | bash
# pattern where the script is read from stdin (not a file) and stdin
# starts as a pipe, exercising the /dev/tty redirect fallback.
SCRIPT="$(cat "$INSTALL_SCRIPT")"
printf '%s\n%s\nyes\n\n\nOK\n\n' "$TEST_PASSPHRASE" "$TEST_PASSPHRASE" \
    | bash -c "$SCRIPT" > "$OUTPUT_FILE" 2>&1 || {
        rc=$?
        echo "install.sh exited with code $rc. Full output:"
        cat "$OUTPUT_FILE"
        # Don't exit immediately — let assertions run so we can see what passed/failed
        echo "install.sh exit code: $rc" >> "$TEST_HOME/exitcode"
    }

echo ""
echo "== Assertions =="

WALLET_CONF="$MONETARIUM_HOME/monetarium-wallet.conf"
NODE_CONF="$MONETARIUM_HOME/monetarium.conf"

check "node binary installed"   test -x /usr/local/bin/monetarium-node
check "wallet binary installed" test -x /usr/local/bin/monetarium-wallet
check "ctl binary installed"    test -x /usr/local/bin/monetarium-ctl

check "wallet config exists"    test -f "$WALLET_CONF"
check "node config exists"      test -f "$NODE_CONF"
# Peer discovery is handled by the HTTPS seeders compiled into chaincfg, so the
# generated config must not pin any hardcoded peers.
check "node config has no hardcoded addpeer" bash -c '! grep -q "^addpeer=" "$0"' "$NODE_CONF"

# Permissions: file mode should be 600 (owner read/write only)
if [[ -f "$WALLET_CONF" ]]; then
    wallet_mode="$(stat -c '%a' "$WALLET_CONF" 2>/dev/null || echo "000")"
    check "wallet config mode is 600" [ "$wallet_mode" = "600" ]
fi

check "wallet config contains passphrase"          grep -q "pass=${TEST_PASSPHRASE}" "$WALLET_CONF"
check "voting disabled in wallet config"             grep -q "enablevoting=0" "$WALLET_CONF"
check "ticket buyer disabled in wallet config"      grep -q "enableticketbuyer=0" "$WALLET_CONF"
check "wallet config has ticketbuyer.limit=1"       grep -q "ticketbuyer.limit=1" "$WALLET_CONF"
check "wallet config has ticketbuyer.balancetomaintainabsolute=1" grep -q "ticketbuyer.balancetomaintainabsolute=1" "$WALLET_CONF"
check "wallet config has gaplimit=20"               grep -q "gaplimit=20" "$WALLET_CONF"
check "wallet config has accountgaplimit=10"        grep -q "accountgaplimit=10" "$WALLET_CONF"
check "mining disabled in node config"              grep -q "generate=false" "$NODE_CONF"
check "passphrase not echoed in script output"      bash -c "! grep -q '$TEST_PASSPHRASE' '$OUTPUT_FILE'"
check "big red warning was printed"                 grep -q "WARNING" "$OUTPUT_FILE"
check "no /dev/tty error leaked to output"          bash -c "! grep -q '/dev/tty' '$OUTPUT_FILE'"
check "no config summary in non-interactive mode"   bash -c "! grep -q 'Configuration Summary' '$OUTPUT_FILE'"

# Wallet database
WALLET_DB="$HOME/.monetarium-wallet/mainnet/wallet.db"
check "wallet database created"     test -f "$WALLET_DB"

# systemd unit files
check "node systemd unit exists"    test -f /etc/systemd/system/monetarium-node.service
check "wallet systemd unit exists"  test -f /etc/systemd/system/monetarium-wallet.service

# Node binary actually runs (quick smoke test: just version or help)
if [[ -x /usr/local/bin/monetarium-node ]]; then
    check "node binary runs (--version)" /usr/local/bin/monetarium-node --version
fi

echo ""
echo "== Cleanup =="
rm -rf "$TEST_HOME"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
