// Copyright (c) 2014-2016 The btcsuite developers
// Copyright (c) 2015-2024 The Decred developers
// Use of this source code is governed by an ISC
// license that can be found in the LICENSE file.

package chaincfg

import (
	"math/big"
	"time"

	"github.com/monetarium/monetarium-node/chaincfg/chainhash"
	"github.com/monetarium/monetarium-node/cointype"
	"github.com/monetarium/monetarium-node/dcrec/secp256k1"
	"github.com/monetarium/monetarium-node/wire"
)

// TestNet3Params return the network parameters for the test currency network.
// This network is sometimes simply called "testnet".
// This is the Monetarium testnet, starting fresh with mainnet-compatible parameters.
func TestNet3Params() *Params {
	// testNetPowLimit is the highest proof of work value a Monetarium block
	// can have for the test network.  It is the value 2^224 - 1 (same as mainnet).
	testNetPowLimit := new(big.Int).Sub(new(big.Int).Lsh(bigOne, 224), bigOne)

	// testNetPowLimitBits is the test network proof of work limit in its
	// compact representation.
	//
	// Note that due to the limited precision of the compact representation,
	// this is not exactly equal to the pow limit.  It is the value:
	//
	// 0x00000000ffff0000000000000000000000000000000000000000000000000000
	const testNetPowLimitBits = 0x1d00ffff // 486604799 (Difficulty 1, same as mainnet)

	// genesisBlock defines the genesis block of the block chain which serves as
	// the public transaction ledger for the Monetarium test network.
	genesisBlock := wire.MsgBlock{
		Header: wire.BlockHeader{
			Version:   1,
			PrevBlock: chainhash.Hash{}, // All zero.
			// MerkleRoot: Calculated below.
			StakeRoot:    chainhash.Hash{},
			Timestamp:    time.Unix(1760649600, 0), // Thu, 16 Oct 2025 00:00:00 GMT (same as mainnet)
			Bits:         testNetPowLimitBits,      // Difficulty 1
			SBits:        2 * 1e8,                  // 2 Coin (same as mainnet)
			Nonce:        0x00000000,
			StakeVersion: 0,
		},
		Transactions: []*wire.MsgTx{{
			SerType: wire.TxSerializeFull,
			Version: 1,
			TxIn: []*wire.TxIn{{
				PreviousOutPoint: wire.OutPoint{
					Hash:  chainhash.Hash{},
					Index: 0xffffffff,
				},
				SignatureScript: hexDecode("0000"),
				Sequence:        0xffffffff,
			}},
			TxOut: []*wire.TxOut{{
				Value:    0x00000000,
				CoinType: cointype.CoinTypeVAR,
				Version:  0x0000,
				PkScript: hexDecode("801679e98561ada96caec2949a5d41c4cab3851e" +
					"b740d951c10ecbcf265c1fd9"),
			}},
			LockTime: 0,
			Expiry:   0,
		}},
	}
	genesisBlock.Header.MerkleRoot = genesisBlock.Transactions[0].TxHashFull()

	return &Params{
		Name:        "testnet3",
		Net:         wire.TestNet3,
		DefaultPort: "19508",
		// DNSSeeds is deprecated and unused; peer discovery is handled by the
		// HTTPS seeders configured below.
		DNSSeeds: nil,

		// Chain parameters.
		//
		// Note that the minimum difficulty reduction parameter only applies up
		// to and including block height 962927.
		GenesisBlock:         &genesisBlock,
		GenesisHash:          genesisBlock.BlockHash(),
		PowLimit:             testNetPowLimit,
		PowLimitBits:         testNetPowLimitBits,
		ReduceMinDifficulty:  true,
		MinDiffReductionTime: time.Minute * 10, // ~99.3% chance to be mined before reduction
		GenerateSupported:    true,
		MaximumBlockSizes:    []int{1310720},
		MaxTxSize:            1000000,
		TargetTimePerBlock:   time.Minute * 2,

		// Version 1 difficulty algorithm (EMA + BLAKE256) parameters.
		WorkDiffAlpha:            1,
		WorkDiffWindowSize:       144,
		WorkDiffWindows:          20,
		TargetTimespan:           time.Minute * 2 * 144, // TimePerBlock * WindowSize
		RetargetAdjustmentFactor: 4,

		// Version 2 difficulty algorithm (ASERT + BLAKE3) parameters.
		WorkDiffV2Blake3StartBits: testNetPowLimitBits,
		WorkDiffV2HalfLifeSecs:    720, // 6 * TimePerBlock (12 minutes)

		// Subsidy parameters.
		BaseSubsidy:              6400000000, // 64 VAR per block (same as mainnet)
		MulSubsidy:               1,          // Numerator for halving (1/2)
		DivSubsidy:               2,          // Denominator for halving (1/2)
		SubsidyReductionInterval: 21600,      // ~1 month for testnet (30 days × 24h × 60min / 2min)
		WorkRewardProportion:     6,
		WorkRewardProportionV2:   5,
		StakeRewardProportion:    3,
		StakeRewardProportionV2:  5,
		BlockTaxProportion:       0,

		// AssumeValid is the hash of a block that has been externally verified
		// to be valid.  It allows several validation checks to be skipped for
		// blocks that are both an ancestor of the assumed valid block and an
		// ancestor of the best header.  It is also used to determine the old
		// forks rejection checkpoint.  This is intended to be updated
		// periodically with new releases.
		//
		// Not set for Monetarium testnet to allow bootstrap from genesis.
		AssumeValid: chainhash.Hash{},

		// MinKnownChainWork is the minimum amount of known total work for the
		// chain at a given point in time.
		//
		// Not set for Monetarium testnet to allow bootstrap from genesis.
		MinKnownChainWork: nil,

		// Consensus rule change deployments.
		//
		// The miner confirmation window is defined as:
		//   target proof of work timespan / target proof of work spacing
		// Testnet shortens the rule-change cycle vs mainnet (mainnet uses
		// RCAI=8064 ≈ 4 weeks at 5-min blocks). At testnet's 2-min block
		// time, RCAI=2016 ≈ 67 h, so a full Defined→Started→LockedIn→Active
		// agenda cycle takes ~3 RCAI ≈ 8.4 days. This keeps testnet vote
		// rehearsals (e.g. SKA2 activation) tractable while still exercising
		// the real threshold-state machine.
		RuleChangeActivationQuorum:     1008, // 10 % of RuleChangeActivationInterval * TicketsPerBlock (2016 * 5 / 10)
		RuleChangeActivationMultiplier: 3,    // 75%
		RuleChangeActivationDivisor:    4,
		RuleChangeActivationInterval:   2016, // ~67 h at 2-min blocks (testnet-only; mainnet=8064)
		Deployments: map[uint32][]ConsensusDeployment{
			4: {{
				Vote: Vote{
					Id:          VoteIDSDiffAlgorithm,
					Description: "Change stake difficulty algorithm as defined in DCP0001",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing algorithm",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new algorithm",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1493164800, // Apr 26th, 2017
				ExpireTime:     1524700800, // Apr 26th, 2018
			}, {
				Vote: Vote{
					Id:          VoteIDLNSupport,
					Description: "Request developers begin work on Lightning Network (LN) integration",
					Mask:        0x0018, // Bits 3 and 4
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain from voting",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "no, do not work on integrating LN support",
						Bits:        0x0008, // Bit 3
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "yes, begin work on integrating LN support",
						Bits:        0x0010, // Bit 4
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1493164800, // Apr 26th, 2017
				ExpireTime: 1508976000, // Oct 26th, 2017
			}},
			5: {{
				Vote: Vote{
					Id:          VoteIDLNFeatures,
					Description: "Enable features defined in DCP0002 and DCP0003 necessary to support Lightning Network (LN)",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1505260800, // Sep 13th, 2017
				ExpireTime:     1536796800, // Sep 13th, 2018
			}},
			6: {{
				Vote: Vote{
					Id:          VoteIDFixLNSeqLocks,
					Description: "Modify sequence lock handling as defined in DCP0004",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1548633600, // Jan 28th, 2019
				ExpireTime:     1580169600, // Jan 28th, 2020
			}},
			7: {{
				Vote: Vote{
					Id:          VoteIDHeaderCommitments,
					Description: "Enable header commitments as defined in DCP0005",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1567641600, // Sep 5th, 2019
				ExpireTime:     1599264000, // Sep 5th, 2020
			}},
			8: {{
				Vote: Vote{
					Id:          VoteIDTreasury,
					Description: "Enable decentralized Treasury opcodes as defined in DCP0006",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1596240000, // Aug 1st, 2020
				ExpireTime: 1627776000, // Aug 1st, 2021
			}},
			9: {{
				Vote: Vote{
					Id:          VoteIDRevertTreasuryPolicy,
					Description: "Change maximum treasury expenditure policy as defined in DCP0007",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1631750400, // Sep 16th, 2021
				ExpireTime: 1694822400, // Sep 16th, 2023
			}, {
				Vote: Vote{
					Id:          VoteIDExplicitVersionUpgrades,
					Description: "Enable explicit version upgrades as defined in DCP0008",
					Mask:        0x0018, // Bits 3 and 4
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain from voting",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0008, // Bit 3
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0010, // Bit 4
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1631750400, // Sep 16th, 2021
				ExpireTime:     1694822400, // Sep 16th, 2023
			}, {
				Vote: Vote{
					Id:          VoteIDAutoRevocations,
					Description: "Enable automatic ticket revocations as defined in DCP0009",
					Mask:        0x0060, // Bits 5 and 6
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0020, // Bit 5
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0040, // Bit 6
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1631750400, // Sep 16th, 2021
				ExpireTime:     1694822400, // Sep 16th, 2023
			}, {
				Vote: Vote{
					Id:          VoteIDChangeSubsidySplit,
					Description: "Change block reward subsidy split to 10/80/10 as defined in DCP0010",
					Mask:        0x0180, // Bits 7 and 8
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain from voting",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0080, // Bit 7
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0100, // Bit 8
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1631750400, // Sep 16th, 2021
				ExpireTime: 1694822400, // Sep 16th, 2023
			}},
			10: {{
				Vote: Vote{
					Id:          VoteIDBlake3Pow,
					Description: "Change proof of work hashing algorithm to BLAKE3 as defined in DCP0011",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				ForcedChoiceID: "yes",
				StartTime:      1682294400, // Apr 24th, 2023
				ExpireTime:     1745452800, // Apr 24th, 2025
			}, {
				Vote: Vote{
					Id:          VoteIDChangeSubsidySplitR2,
					Description: "Change block reward subsidy split to 1/89/10 as defined in DCP0012",
					Mask:        0x0060, // Bits 5 and 6
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain voting for change",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep the existing consensus rules",
						Bits:        0x0020, // Bit 5
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "change to the new consensus rules",
						Bits:        0x0040, // Bit 6
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1682294400, // Apr 24th, 2023
				ExpireTime: 1745452800, // Apr 24th, 2025
			}},
			// Version 11 carries the SKA2 activation agenda. Once it
			// reaches ThresholdActive, ska_emission.go's gate
			// (`hasVotePassed("activateska2", prevNode)`) opens and an
			// emission tx for SKA2 becomes valid inside its emission
			// window (testnet: blocks 30000–30999). Real stakeholder
			// voting is required — no ForcedChoiceID — so this exercises
			// the same vote path that mainnet will use when SKA2 is
			// finally proposed there.
			11: {{
				Vote: Vote{
					Id:          VoteIDActivateSKA2,
					Description: "Activate SKA2 (Skarb-2) coin type for transactions",
					Mask:        0x0006, // Bits 1 and 2
					Choices: []Choice{{
						Id:          "abstain",
						Description: "abstain from voting",
						Bits:        0x0000,
						IsAbstain:   true,
						IsNo:        false,
					}, {
						Id:          "no",
						Description: "keep SKA2 inactive",
						Bits:        0x0002, // Bit 1
						IsAbstain:   false,
						IsNo:        true,
					}, {
						Id:          "yes",
						Description: "activate SKA2 for use",
						Bits:        0x0004, // Bit 2
						IsAbstain:   false,
						IsNo:        false,
					}},
				},
				StartTime:  1767225600, // Jan 1, 2026 UTC — agenda eligible from genesis on a fresh testnet relaunch
				ExpireTime: 1798761600, // Jan 1, 2027 UTC — 1-year window for stakers to converge
			}},
		},

		// Enforce current block version once majority of the network has
		// upgraded.
		// 51% (51 / 100)
		// Reject previous block versions once a majority of the network has
		// upgraded.
		// 75% (75 / 100)
		BlockEnforceNumRequired: 51,
		BlockRejectNumRequired:  75,
		BlockUpgradeNumToCheck:  100,

		// AcceptNonStdTxs is a mempool param to either accept and relay non
		// standard txs to the network or reject them
		AcceptNonStdTxs: true,

		// Address encoding magics
		NetworkAddressPrefix: "T",
		PubKeyAddrID:         [2]byte{0x28, 0xf7}, // starts with Tk
		PubKeyHashAddrID:     [2]byte{0x0f, 0x21}, // starts with Ts
		PKHEdwardsAddrID:     [2]byte{0x0f, 0x01}, // starts with Te
		PKHSchnorrAddrID:     [2]byte{0x0e, 0xe3}, // starts with TS
		ScriptHashAddrID:     [2]byte{0x0e, 0xfc}, // starts with Tc
		PrivateKeyID:         [2]byte{0x23, 0x0e}, // starts with Pt

		// BIP32 hierarchical deterministic extended key magics
		HDPrivateKeyID: [4]byte{0x04, 0x35, 0x83, 0x97}, // starts with tprv
		HDPublicKeyID:  [4]byte{0x04, 0x35, 0x87, 0xd1}, // starts with tpub

		// BIP44 coin type used in the hierarchical deterministic path for
		// address generation.
		SLIP0044CoinType: 1,  // SLIP0044, Testnet (all coins)
		LegacyCoinType:   11, // for backwards compatibility

		// Decred PoS parameters
		MinimumStakeDiff:     2 * 1e8, // 2 Coin (same as mainnet)
		TicketPoolSize:       1024,
		TicketsPerBlock:      5,
		TicketMaturity:       16,
		TicketExpiry:         6144, // 6*TicketPoolSize
		CoinbaseMaturity:     16,
		SStxChangeMaturity:   1,
		TicketPoolSizeWeight: 4,
		StakeDiffAlpha:       1,
		StakeDiffWindowSize:  144,
		StakeDiffWindows:     20,
		// Testnet shortens SVI vs mainnet so the chain's stake version can
		// advance fast enough to gate on-chain agenda voting (e.g. SKA2
		// activation). First SVI window closes at StakeValidationHeight+SVI
		// = 768 + 504 = 1272 (~17 h after stake validation begins). Mainnet
		// uses 2016 (~1 week at 5-min blocks).
		StakeVersionInterval:    504,     // ~17 h at 2-min blocks (testnet-only; mainnet=2016)
		MaxFreshStakePerBlock:   20,      // 4*TicketsPerBlock
		StakeEnabledHeight:      16 + 16, // CoinbaseMaturity + TicketMaturity
		StakeValidationHeight:   768,     // Arbitrary
		StakeBaseSigScript:      []byte{0x00, 0x00},
		StakeMajorityMultiplier: 3,
		StakeMajorityDivisor:    4,

		// Monetarium has no treasury (BlockTaxProportion = 0)
		OrganizationPkScript:        nil,
		OrganizationPkScriptVersion: 0,
		BlockOneLedger:              nil, // Monetarium has no premine

		// Monetarium has no Politeia/treasury system
		PiKeys: [][]byte{},

		// ~2 hours for tspend inclusion
		TreasuryVoteInterval: 60,

		// ~4.8 hours for short circuit approval
		TreasuryVoteIntervalMultiplier: 4,

		// ~1 day policy window
		TreasuryExpenditureWindow: 4,

		// ~6 day policy window check
		TreasuryExpenditurePolicy: 3,

		// 10000 dcr/tew as expense bootstrap
		TreasuryExpenditureBootstrap: 10000 * 1e8,

		TreasuryVoteQuorumMultiplier:   1, // 20% quorum required
		TreasuryVoteQuorumDivisor:      5,
		TreasuryVoteRequiredMultiplier: 3, // 60% yes votes required
		TreasuryVoteRequiredDivisor:    5,

		// HTTPS seeders used for peer discovery.
		seeders: []string{"seed.testnet.monetarium.online"},

		// SKA coin type configurations (fast testing values)
		SKACoins: map[cointype.CoinType]*SKACoinConfig{
			1: {
				CoinType:         1,
				Name:             "Skarb-1",
				Symbol:           "SKA1",
				EmissionHeight:   800,                                                  // After stake validation (768)
				EmissionWindow:   4096,                                                 // 4096 block window for testing
				MaxSupply:        mustParseBigInt("900000000000000000000000000000000"), // 900 trillion * 1e18 atoms
				AtomsPerCoin:     mustParseBigInt("1000000000000000000"),               // 1e18
				Active:           true,
				Description:      "Primary asset-backed SKA coin type for testnet",
				MinRelayTxFee:    mustParseBigInt("4000000000000000000"), // 4 SKA per KB (4e18 atoms/KB)
				MaxFeeMultiplier: 2500,                                   // Max fee is 2500x min fee
				EmissionAddresses: []string{
					"TsXsf3yJokKWxbNboXtABCUaLk61R4RLAAn", // REPLACE with real testnet address
				},
				EmissionAmounts: bigIntSlice(
					"900000000000000000000000000000000", // 900 trillion * 1e18 atoms
				),
				// SECURITY NOTE: This is a placeholder key for development ONLY
				EmissionKey: mustParseHexPubKeyTestnet("029e89de8077c4105d826a608e1830d2ee625c8f567de644f3ca1748406915cefb"),
			},
			2: {
				CoinType:     2,
				Name:         "Skarb-2",
				Symbol:       "SKA2",
				MaxSupply:    mustParseBigInt("5000000000000000000000000"), // 5 million * 1e18 atoms
				AtomsPerCoin: mustParseBigInt("1000000000000000000"),       // 1e18
				// EmissionHeight is set just past the best-case vote-cycle
				// completion (~block 7400 = ~1 SVI of 504 blocks for
				// stake-version upgrade + 3 RCAI of 2016 blocks each for
				// Defined→Started→LockedIn→Active). 10,000 keeps "happy
				// path" emission within ~14 days of testnet genesis while
				// still giving ~3.6 d of buffer between best-case
				// activation and the window opening.
				EmissionHeight: 10000, // ~14 d post-genesis at 2-min blocks
				// 30,000-block window (~42 d) absorbs up to ~16 failed
				// RCAI vote windows (each adds 2016 blocks of slip)
				// without losing the emission opportunity. The window is
				// purely permissive — wider just means more deadline
				// slack; no security/correctness scaling with width.
				EmissionWindow:   30000,
				Active:           true,
				Description:      "Secondary SKA coin type for testnet testing",
				MinRelayTxFee:    mustParseBigInt("4000000000000000000"), // 4 SKA per KB (4e18 atoms/KB)
				MaxFeeMultiplier: 2500,                                   // Max fee is 2500x min fee
				EmissionAddresses: []string{
					"TsXsf3yJokKWxbNboXtABCUaLk61R4RLAAn",
				},
				EmissionAmounts: bigIntSlice(
					"5000000000000000000000000", // 5 million * 1e18 atoms
				),
				// SECURITY NOTE: This is a placeholder key for development ONLY
				EmissionKey: mustParseHexPubKeyTestnet("03f8b95a72b0bbe48836733e4c044f5d07230ee99028815928ce4910d33b1ee204"),
			},
		},

		// Initial SKA types to activate at network genesis
		InitialSKATypes: []cointype.CoinType{1},
	}
}

// mustParseHexPubKeyTestnet parses a hex-encoded public key for testnet.
// SECURITY WARNING: These are placeholder keys - production must use secure key generation.
func mustParseHexPubKeyTestnet(hexStr string) *secp256k1.PublicKey {
	keyBytes := mustParseHex(hexStr)
	pubKey, err := secp256k1.ParsePubKey(keyBytes)
	if err != nil {
		panic("failed to parse public key: " + err.Error())
	}
	return pubKey
}
