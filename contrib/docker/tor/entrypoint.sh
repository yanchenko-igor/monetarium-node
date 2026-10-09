#!/bin/sh
set -eu

###############################################################################
# Monetarium Tor Node Entrypoint
#
# Starts a local Tor daemon that serves a v3 hidden service for the p2p port,
# waits for the service's hostname to be published, and then starts the node
# with:
#   - --onion pointing at the local Tor SOCKS proxy so that .onion peers
#     discovered from the HTTPS seeders can actually be dialed,
#   - --onionaddr set to this container's own hidden service address so it is
#     announced to onion peers via the addrv2 message,
#   - the HTTPS seeders enabled so the node discovers peers over clearnet and
#     requests the full-address (onion included) listing since Tor is usable.
###############################################################################

# Runtime data directory.  Persist it with a volume to keep the same onion
# identity (private key) and blockchain across restarts.
MONETARIUM_DATA=${MONETARIUM_DATA:-/home/monetarium}

# Tor data directory.  Kept inside the data directory so that a single volume
# keeps everything durable and the root filesystem can remain read-only.
TOR_DATA_DIR=${TOR_DATA_DIR:-"$MONETARIUM_DATA/tor"}
TOR_SERVICE_DIR="$TOR_DATA_DIR/hidden_service"

# P2P port that the hidden service forwards to.  Mainnet is 9508 and testnet
# is 19508; combine ONION_P2P_PORT with a --testnet argument accordingly.
ONION_P2P_PORT=${ONION_P2P_PORT:-9508}

# SOCKS port Tor listens on for onion dialing.
ONION_SOCKS_PORT=${ONION_SOCKS_PORT:-9050}

# Host the hidden service forwards to (the node listens on all interfaces).
HIDDEN_SERVICE_TARGET=${HIDDEN_SERVICE_TARGET:-127.0.0.1}

mkdir -p "$MONETARIUM_DATA" "$TOR_DATA_DIR" "$TOR_SERVICE_DIR"

# Tor requires the data directory and hidden service directory to be private
# to the tor user; enforce that even when a host-provided volume supplies
# looser permissions.
chmod 700 "$TOR_DATA_DIR"
chmod 700 "$TOR_SERVICE_DIR"

# Write out the tor configuration.  Only the options needed for the node are
# set; everything else uses tor's compiled-in defaults.
cat > "$TOR_DATA_DIR/torrc" <<EOF
SOCKSPort 127.0.0.1:$ONION_SOCKS_PORT
DataDirectory $TOR_DATA_DIR
HiddenServiceDir $TOR_SERVICE_DIR
HiddenServicePort $ONION_P2P_PORT $HIDDEN_SERVICE_TARGET:$ONION_P2P_PORT
Log notice stdout
DisableNetwork 0
EOF

# Start Tor.
tor -f "$TOR_DATA_DIR/torrc" &
tor_pid=$!
echo "Started tor (pid $tor_pid)"

# Forward SIGTERM/SIGINT to the node and tor for a graceful shutdown.
# Wait for the node to exit before stopping tor and terminating PID 1,
# so the database is closed cleanly.
# shellcheck disable=SC2329 # Invoked by the signal trap.
term_handler() {
    if [ -n "${node_pid:-}" ]; then
        kill -TERM "$node_pid" 2>/dev/null || true
        wait "$node_pid" 2>/dev/null || true
    fi
    if [ -n "${tor_pid:-}" ]; then
        kill -TERM "$tor_pid" 2>/dev/null || true
        wait "$tor_pid" 2>/dev/null || true
    fi
    exit 143
}
trap term_handler TERM INT

# Wait for Tor to generate the v3 key and publish the hostname.
i=0
while [ ! -s "$TOR_SERVICE_DIR/hostname" ] && [ "$i" -lt 180 ]; do
    i=$((i + 1))
    sleep 1
done
if [ ! -s "$TOR_SERVICE_DIR/hostname" ]; then
    echo "error: Tor did not publish a hidden service hostname in time" >&2
    kill -TERM "$tor_pid" 2>/dev/null || true
    exit 1
fi
onion_host=$(tr -d ' \t\r\n' < "$TOR_SERVICE_DIR/hostname")
echo "Hidden service ready: $onion_host:$ONION_P2P_PORT"

# Preserve argument boundaries, including data directories containing spaces.
if [ "${MON_NO_FILE_LOGGING:-true}" != "false" ]; then
    set -- --nofilelogging "$@"
fi
monetarium-node "--appdata=$MONETARIUM_DATA" \
    "--onion=127.0.0.1:$ONION_SOCKS_PORT" \
    "--onionaddr=$onion_host:$ONION_P2P_PORT" "$@" &
node_pid=$!
echo "Started monetarium-node (pid $node_pid)"

# Wait for the node and stop tor once it exits.
rc=0
wait "$node_pid" || rc=$?
kill -TERM "$tor_pid" 2>/dev/null || true
wait "$tor_pid" || true
exit "$rc"
