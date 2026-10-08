Monetarium Tor Node for Docker
==============================

## Overview

This directory provides the files to build a Docker image that runs a full
Monetarium node together with a local Tor daemon so that the node participates
in the network over Tor:

- The local Tor daemon serves a **v3 hidden service** on the p2p port.
- The node is configured (`--onion`) to dial `.onion` peers through the local
  Tor SOCKS proxy, so onion addresses received from the network are reachable.
- The node queries the **HTTPS seeders** over clearnet to discover peers.  Since
  Tor is enabled it requests the full-address listing, which includes onion
  addresses.
- The node **announces its own hidden service address** (`--onionaddr`) to onion
  peers via the `addrv2` wire message.

The image builds the node from the **local source tree** (the build context).
Before building, merge the onion discovery and HTTPS seeder changes, publish
their changed Go submodules, and bump the consuming module requirements.
The Docker build disables workspace mode and resolves those published versions;
it requires a node that supports `--onionaddr` and protocol version 14.

## Security Properties

- Runs as a non-root user (static UID/GID `10000:10000`).
- The root filesystem can be mounted `--read-only`; all mutable state lives in
  the data volume (blockchain, config, RPC credentials, and the Tor identity).
- The RPC server binds only to the loopback interface inside the container.

## Quick Start

Build from the repository root:

```sh
$ docker build -t monetarium/tor-node -f contrib/docker/tor/Dockerfile .
```

Create the data volume and run:

```sh
$ docker volume create monetarium-tor-data
$ docker run -d \
    --name monetarium-tor \
    --read-only \
    -v monetarium-tor-data:/home/monetarium \
    -p 9508:9508 \
    monetarium/tor-node
```

Because the node connects outbound to the seeders (clearnet) and to onion peers
(through Tor), no inbound port mapping is strictly required.  Publishing the p2p
port (`-p 9508:9508`) additionally allows clearnet peers to connect if the host
is reachable.

## Verifying It Works

```sh
$ docker logs -f monetarium-tor
```

The startup sequence should show, in order:

1. `Started tor ...`
2. `Hidden service ready: <something>.onion:9508`
3. The node starting; shortly after, a seeder line such as:
   `seeder 'seed.monetarium.online' ...` or successful peer dials, and incoming
   requests for its address list.

Use the seeders' returned onion peers to confirm outbound onion dialing:

```
... attempting fixup stale connection ...
... New valid peer ...
```

## Testnet

Tor's hidden service port and the node's network must line up.  Run with:

```sh
$ docker run -d \
    --name monetarium-tor-testnet \
    --read-only \
    -v monetarium-tor-testnet-data:/home/monetarium \
    -e ONION_P2P_PORT=19508 \
    -p 19508:19508 \
    monetarium/tor-node --testnet
```

## Environment Variables

| Variable                 | Default              | Description                                                    |
| ------------------------ | -------------------- | -------------------------------------------------------------- |
| `MONETARIUM_DATA`        | `/home/monetarium`   | Node data directory; persist this with a volume.               |
| `ONION_P2P_PORT`         | `9508`               | P2P port the hidden service forwards to (19508 on testnet).    |
| `ONION_SOCKS_PORT`       | `9050`               | SOCKS port Tor listens on for onion dialing.                   |
| `HIDDEN_SERVICE_TARGET`  | `127.0.0.1`          | Interface the hidden service forwards to.                      |
| `TOR_DATA_DIR`           | `$MONETARIUM_DATA/tor` | Tor state (keys, consensus, hidden service).                  |
| `MON_NO_FILE_LOGGING`    | `true`               | Set to `false` to also write per-process log files.            |

Any additional arguments passed to `docker run ... <image> ...` are forwarded to
the node binary (`monetarium-node`).

## Notes

- The hidden service private key lives under `$TOR_DATA_DIR/hidden_service`, so
  keeping the volume means the node keeps the **same onion address** across
  restarts.  Deleting the volume mints a new one.
- The onion address is announced only to peers that negotiate the `addrv2`
  message (pver >= 14); older peers never learn it.
- The image contains only the node binary and Tor; `monctl` is not included.
