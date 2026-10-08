#!/usr/bin/env bash
# Functional test for install.sh, macOS path.
#
# Strategy:
#   - Put tests/mocks/ first on PATH so install.sh's `curl` calls are
#     intercepted (see mocks/curl) instead of hitting the real
#     monetarium GitHub releases.
#   - Use a throwaway $HOME so config files land somewhere we can
#     inspect and clean up.
#   - Feed the passphrase prompts via stdin instead of a real TTY.
#   - Assert on the resulting files/permissions/services, and make sure
#     the passphrase itself never shows up in the script's own output.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/install.sh"
MOCK_BIN="$REPO_ROOT/tests/mocks"
TEST_PASSPHRASE="correct-horse-battery-staple-test-only"

PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@"; then
        echo "  ✅ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ❌ $desc"
        FAIL=$((FAIL + 1))
    fi
}

[[ "$(uname -s)" == "Darwin" ]] || { echo "This test is intended for macOS runners only."; exit 1; }
[[ -f "$INSTALL_SCRIPT" ]] || { echo "install.sh not found at $INSTALL_SCRIPT"; exit 1; }

# Isolated fake HOME so we don't touch the real runner user's files
export TEST_HOME
TEST_HOME="$(mktemp -d)"
export HOME="$TEST_HOME"
export MONETARIUM_HOME="$TEST_HOME/.monetarium"

# Put mocks ahead of the real tools on PATH
export PATH="$MOCK_BIN:$PATH"

echo "== Running install.sh (mocked network) =="
OUTPUT_FILE="$TEST_HOME/install-output.log"
# Run via bash -c "$(cat install.sh)" to simulate curl|bash (script
# from stdin, stdin as pipe), exercising the /dev/tty redirect fallback.
SCRIPT="$(cat "$INSTALL_SCRIPT")"
printf '%s\n%s\n' "$TEST_PASSPHRASE" "$TEST_PASSPHRASE" \
    | bash -c "$SCRIPT" > "$OUTPUT_FILE" 2>&1 || {
        echo "install.sh exited non-zero. Full output:"
        cat "$OUTPUT_FILE"
        exit 1
    }

echo
echo "== Assertions =="

WALLET_CONF="$MONETARIUM_HOME/monetarium-wallet.conf"
NODE_CONF="$MONETARIUM_HOME/monetarium.conf"

check "node binary installed"   test -x /usr/local/bin/monetarium-node
check "wallet binary installed" test -x /usr/local/bin/monetarium-wallet
check "ctl binary installed"    test -x /usr/local/bin/monetarium-ctl

check "wallet config exists" test -f "$WALLET_CONF"
check "node config exists"   test -f "$NODE_CONF"
# Peer discovery is handled by the HTTPS seeders compiled into chaincfg, so the
# generated config must not pin any hardcoded peers.
check "node config has no hardcoded addpeer" bash -c '! grep -q "^addpeer=" "$0"' "$NODE_CONF"

# Permissions: file mode should be 600 (owner read/write only)
wallet_mode="$(stat -f '%Lp' "$WALLET_CONF" 2>/dev/null || stat -c '%a' "$WALLET_CONF")"
check "wallet config mode is 600" [ "$wallet_mode" = "600" ]

check "wallet config contains passphrase" grep -q "pass=${TEST_PASSPHRASE}" "$WALLET_CONF"
check "voting disabled in wallet config"      grep -q "enablevoting=0" "$WALLET_CONF"
check "ticket buyer disabled in wallet config" grep -q "enableticketbuyer=0" "$WALLET_CONF"
check "wallet config has ticketbuyer.limit=1" grep -q "ticketbuyer.limit=1" "$WALLET_CONF"
check "wallet config has ticketbuyer.balancetomaintainabsolute=1" grep -q "ticketbuyer.balancetomaintainabsolute=1" "$WALLET_CONF"
check "wallet config has gaplimit=20"         grep -q "gaplimit=20" "$WALLET_CONF"
check "wallet config has accountgaplimit=10"  grep -q "accountgaplimit=10" "$WALLET_CONF"
check "mining disabled in node config"        grep -q "generate=false" "$NODE_CONF"

check "passphrase not echoed in script output" bash -c "! grep -q '$TEST_PASSPHRASE' '$OUTPUT_FILE'"

check "big red warning was printed" grep -q "WARNING" "$OUTPUT_FILE"

check "no config summary in non-interactive mode" bash -c "! grep -q 'Configuration Summary' '$OUTPUT_FILE'"

WALLET_DB="$HOME/Library/Application Support/Monetarium-wallet/mainnet/wallet.db"
check "wallet database created"     test -f "$WALLET_DB"

check "node launchd plist exists"   test -f "$HOME/Library/LaunchAgents/com.monetarium.node.plist"
check "wallet launchd plist exists" test -f "$HOME/Library/LaunchAgents/com.monetarium.wallet.plist"

check "node service loaded"   bash -c "launchctl list | grep -q com.monetarium.node"
check "wallet service loaded" bash -c "launchctl list | grep -q com.monetarium.wallet"

echo
echo "== Cleanup =="
launchctl unload "$HOME/Library/LaunchAgents/com.monetarium.node.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.monetarium.wallet.plist" 2>/dev/null || true
sudo rm -f /usr/local/bin/monetarium-node /usr/local/bin/monetarium-wallet /usr/local/bin/monetarium-ctl
rm -rf "$TEST_HOME"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
