module github.com/monetarium/monetarium-node/connmgr

go 1.23

toolchain go1.23.4

require (
	github.com/decred/slog v1.2.0
	github.com/monetarium/monetarium-node/crypto/rand v1.3.9
	github.com/monetarium/monetarium-node/wire v1.3.9
	golang.org/x/crypto v0.33.0
)

replace github.com/monetarium/monetarium-node/wire => github.com/yanchenko-igor/monetarium-node/wire v1.0.12-0.20261008172943-37c1aad4aa4d

require (
	github.com/klauspost/cpuid/v2 v2.0.9 // indirect
	github.com/monetarium/monetarium-node/chaincfg/chainhash v1.3.9 // indirect
	github.com/monetarium/monetarium-node/cointype v1.3.9 // indirect
	github.com/monetarium/monetarium-node/crypto/blake256 v1.3.9 // indirect
	golang.org/x/sys v0.30.0 // indirect
	lukechampine.com/blake3 v1.3.0 // indirect
)
