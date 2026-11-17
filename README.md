# Morpheus bug-bounty PoCs

Two Foundry proof-of-concept tests for Morpheus smart-contract findings
(appendix-A deployed contracts). No privileged accounts; attacker is a
fresh EOA. RPC URLs are public endpoints, hardcoded in the tests.

## Setup

```shell
forge install foundry-rs/forge-std --no-commit
```

## Run

```shell
forge test --match-contract PocYieldShareDonationTest -vv  # Ethereum fork, block 26433183
forge test --match-contract PocBuildersFreezeTest -vv      # Base fork, block 58543593
```

## Findings

1. `PocYieldShareDonation.t.sol` — Distributor counts directly-donated
   aTokens as pool yield, skewing MOR emission toward the donating pool.
2. `PocBuildersFreeze.t.sol` — any subnet admin can raise the withdraw
   lock period after deposits, freezing all stakers' funds indefinitely.
