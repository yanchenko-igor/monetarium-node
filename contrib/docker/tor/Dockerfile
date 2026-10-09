###############
# Builder Stage
###############

# Basic Go environment with git and SSL CA certs.
# The image below is golang:1.24.2-alpine3.21 (linux/amd64).
# It's pulled by the digest (immutable id) to avoid supply-chain attacks.
# Maintainer Note:
#    To update to a new digest, you must first manually pull the new image:
#    `docker pull golang:<new version>`
#    Docker will print the digest of the new image after the pull has finished.
FROM golang@sha256:7772cb5322baa875edd74705556d08f0eeca7b9c4b5367754ce3f2f00041ccee AS builder
RUN apk add --no-cache git ca-certificates

# Build from a source tree whose module requirements reference published
# addrv2/Tor v3 and HTTPS seeder releases.  See README.md for prerequisites.
WORKDIR /src
COPY . .

RUN GOWORK=off go mod edit \
      -replace=github.com/monetarium/monetarium-node/wire=github.com/yanchenko-igor/monetarium-node/wire@v1.0.12-0.20261008172943-37c1aad4aa4d \
      -replace=github.com/monetarium/monetarium-node/addrmgr=github.com/yanchenko-igor/monetarium-node/addrmgr@v1.0.12-0.20261008172943-37c1aad4aa4d \
      -replace=github.com/monetarium/monetarium-node/peer=github.com/yanchenko-igor/monetarium-node/peer@v1.0.12-0.20261008172943-37c1aad4aa4d \
      -replace=github.com/monetarium/monetarium-node/chaincfg=github.com/yanchenko-igor/monetarium-node/chaincfg@v1.0.12-0.20261008173812-a6b8cb02e08b \
      -replace=github.com/monetarium/monetarium-node/connmgr=github.com/yanchenko-igor/monetarium-node/connmgr@v1.0.12-0.20261008203546-fd759b0e6b84 \
    && GOWORK=off go mod tidy \
    && GOWORK=off CGO_ENABLED=0 GOOS=linux \
    go build -trimpath -tags safe,netgo,timetzdata \
      -ldflags="-s -w" \
      -o /out/monetarium-node .

##################
# Runtime image
##################

# Debian slim provides the tor package which is what this image is about.
# Pinned by digest to match the builder stage.
FROM debian@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587

RUN apt-get update \
 && apt-get install -y --no-install-recommends tor ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# New unprivileged user for the node and the tor daemon.  Tor is happy to run
# as any non-root user; keeping everything under a single uid keeps the image
# simple and non-root.
ENV USER=monetarium
ENV UID=10000
RUN groupadd --gid "${UID}" "${USER}" \
 && useradd --uid "${UID}" --gid "${UID}" --shell /usr/sbin/nologin --no-create-home "${USER}" \
 && mkdir -p /home/monetarium \
 && chown -R "${UID}:${UID}" /home/monetarium

COPY --from=builder /out/monetarium-node /usr/local/bin/monetarium-node
COPY contrib/docker/tor/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod +x /usr/local/bin/entrypoint

USER monetarium

ENV MONETARIUM_DATA=/home/monetarium

# P2P ports for mainnet and testnet.
EXPOSE 9508 19508

ENTRYPOINT ["/usr/local/bin/entrypoint"]
