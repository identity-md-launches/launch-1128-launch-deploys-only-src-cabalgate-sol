# CabalGate launch adaptation (launch 990 retry)

This is a contracts-only launch of **CabalGate** on Ethereum mainnet (chain id 1) for the
live CabalHook `0xf41b6ff942a082c0d320a0c151310ac2a922a0c0` of launch 953. CabalHook and
CabalCoin are not deployed and their source is unchanged. No transactions were broadcast.

## Why launch 990 parked, and what changed

The launch checks (`Contracts.protected.t.sol`) deploy the gate by CREATE2 in an empty EVM
where the hook, the PoolManager, the Intake and IMD have no code. The previous constructor
called `hook.initialized()`, `poolManager()`, `cabal()`, `poolKey()` and `imd()` and required
code at the Intake and IMD, so the probe reverted with "application constructor failed".

The constructor now makes **no external calls and no code-length checks**. Everything it
needs arrives as nineteen flat static words, and the facts it used to read from the hook are
checked at every submission instead, where the chain is live.

| File | Change | Required by |
| --- | --- | --- |
| `src/CabalGate.sol` | Constructor takes, in order: hook, poolManager, cabal, currency0, currency1, fee, tickSpacing, initialOwner, intake, imd, signer, action, maxBuyAmount, maxSellAmount, maxImpactBps, maxDriftBps, panelSize, quorum, windowHours. It stores hook, poolManager and cabal as immutables (the `hook()` and `cabal()` getters that `hook.setGate` checks are kept), builds the PoolKey from currency0, currency1, fee, tickSpacing and `hooks = hook`, stores `keccak256(abi.encode(key))` as an immutable, creates QuestionBuilder and ImpactEstimator as before, builds Config with `oracleVerifier = address(this)` and `boolAnswerType = 0` and validates only what needs no chain state: non-zero hook, poolManager, cabal, currency0, intake, imd, signer and action; `currency0 < currency1`; cabal is one of the two currencies and imd the other; tickSpacing in 1..2^23-1; the numeric limits as before. `tickSpacing` is declared `uint24` and narrowed to `int24` because the launch ABI has no signed integers. | Launch rule: the factory calls the constructor in an empty EVM; audit finding `6bbf556f…` (high) and `ebf30b4d…` (info). |
| `src/CabalGate.sol` | `_submit` (both buy and sell) now requires, after the existing `block.chainid == 1` check and before anything else: `hook.poolKey()` returns exactly `abi.encode(stored key)` (compared raw against the immutable key hash), `hook.gate() == address(this)` (already there), `hook.cabal() == cabal` and `hook.imd() == cfg.imd`; otherwise `InvalidConfig`, before any oracle payment or request creation. | Brief; audit finding `6bbf556f…`. |
| `src/CabalGate.sol` | `configure` (owner, live chain) keeps the checks the constructor cannot make: Intake and IMD must have code and IMD must equal `hook.imd()`. The chain-free validation moved into `_configure`, shared by both paths. | Brief: "the owner's later reconfiguration may keep its intake/imd code-length checks". |
| `src/CabalGate.sol` | `_configure` now requires `2 <= quorum <= panelSize <= 300` instead of `1 <= quorum <= panelSize <= 1000`. The launch values (30, 20) are inside. | Audit finding `7640e8a5…` (low), reproduced: the oracle refuses bodies outside 2..300 and the 0.5 IMD is spent with no callback. |
| `src/CabalGate.sol` | Removed the unused `mainnetConfig(...)` view (nothing on chain or in production called it). | EIP-170: the submission checks grew the runtime past 24,576 bytes; the audit (`72c9545e…`, info) named this view as the safe place to recover bytes. See sizes below. |
| `launch.json` | Deleted. It carried the thirteen-word constructor that parked launch 990 and notes asserting the hook is read in the constructor. The manifest step writes the new one after this work is accepted; the brief's nineteen values are transcribed in `docs/DEPLOYMENT.md`. | Launch rule: a launch.json in the builder's tree is checked as a manifest; audit finding `e1cb934d…` (medium). |
| `test/GateLaunch.t.sol` | Rewritten. `GateEmptyEvmLaunchTest` deploys the gate with the nineteen manifest words where no code exists at the hook, PoolManager, Intake, IMD or CABAL addresses and asserts it deploys, with the floor's size and opcode checks on the gate and both helpers. `GateLaunchTest` deploys the same words against a mock hook at the live address that reports initialized, poolKey, poolManager, imd, cabal and gate like the live one: owner-only one-time `setGate` that refuses a second gate; a buy and a sell request that are refused (without payment) before binding and succeed once the hook reports this gate; requests refused when the hook reports another key (fee, tickSpacing, hooks, currency order), another CABAL, another IMD, no gate or another gate, then accepted again once the reads match; a gate built with swapped CABAL/IMD roles is refused by the hook; every constructor validation; the constructor ignores dependency code and hook state; the owner's live `configure` checks and the 2..300 panel bound. | Brief's TESTS section; audit finding `3a98ab45…` (low). |
| `test/GateFactoryEdges.t.sol` | Updated to the nineteen words: fuzzed and pinned numeric edges, dirty high bits in every narrow word (now including the two `uint24` words), truncated argument lists, helper rollback after a failed constructor validation. | Same. |
| `test/CabalFixture.sol` | `deployGate` passes the nineteen words, copying the pool from the local hook. | Constructor change. |
| `test/AdversarialOracle.t.sol` | Configuration-boundary loop adds quorum 1, panel 301 and panel 1 as refused; the largest accepted panel is now (300, 300) and the smallest (2, 2). `test_mainnetDefaultsMatchAssignment` checks the `MainnetDefaults` constants and the live configuration instead of the removed view. | Findings `7640e8a5…` and `72c9545e…`. |
| `README.md`, `docs/DEPLOYMENT.md`, `test/README.md`, `test/GateLaunchChecks.md` | Document the nineteen-word constructor, the empty-EVM rehearsal, the submission-time hook checks, the hook owner's pre-binding key check and the removed manifest. | Documentation of the above. |

Everything else in the gate is as audited: the oracle attestation struct, type string and
domain, the request flow, callback, execution, fees, limits, getters and ownership.

## Imported audit disposition

1. **`6bbf556f…` (high) constructor needs chain state: reproduced and fixed.** The supplied
   proof (`.imd/reads/proofs/Proof_6bbf556fe5fd.t.sol`) is the model for
   `GateEmptyEvmLaunchTest`, which fails on the old source and passes now.
2. **`e1cb934d…` (medium) stale thirteen-word launch.json: reproduced, resolved by removing
   the file.** The brief says the manifest step writes launch.json; a stale one in the tree
   would be checked as a manifest and reject the work.
3. **`7640e8a5…` (low) panel/quorum outside the oracle's 2..300: reproduced** (`configure`
   with quorum 1 was accepted) **and fixed** with the tightened bound and tests in
   `AdversarialOracle.t.sol` and `GateLaunch.t.sol`.
4. **`3a98ab45…` (low) rehearsal etched code at the dependency addresses: reproduced and
   fixed.** The inverted test that expected deployment to fail without code is gone; the
   empty-EVM test and the mock-hook tests replace it.
5. **`72c9545e…` (info) runtime near EIP-170: measured.** With Foundry 1.8.3 and solc
   0.8.26 (via IR, 200 runs, cancun) the delivered artifact is **24,443 bytes of runtime**
   (133 below 24,576) and **37,403 bytes of creation code** (38,011 with the nineteen words,
   below 49,152). The submission checks alone added about 1.4 KB; comparing the raw
   `poolKey()` return data against a constructor-computed key hash recovered 594 bytes and
   removing `mainnetConfig` recovered 309 more. The empty-EVM test asserts both bounds.
6. **`ebf30b4d…` (info) tickSpacing is int24: applied.** The parameter is `uint24`, bounded
   to 1..2^23-1 and narrowed to `int24`; the word `60` is identical either way.
7. **`04a9da91…` (info) setGate does not check the key: procedural guard documented, not a
   code change in the hook (which is live and out of scope).** `docs/DEPLOYMENT.md` tells
   the hook owner to recompute `keccak256(abi.encode(hook.poolKey()))` and compare it with
   the key built from the manifest words before the one-time binding, and the gate refuses
   every submission while the hook's key differs, so a wrong word is visible before funds
   move. `GateLaunchTest` asserts the manifest words hash to the key the (mock) hook reports
   and that a gate with swapped token roles cannot be bound.

## Launch handoff

After deployment the hook owner (`0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`, owner of
launch 953's hook) calls `hook.setGate(gate)` once, after the checks above. `$owner` becomes
the gate owner through `Ownable(initialOwner)`; the factory holds no role. No address was
guessed and no stand-in was used.

## Validation

With the project's own configuration, offline and with no environment inputs: `forge build`
passed (Foundry 1.8.3, solc 0.8.26) and `forge test` passed **166 tests in 25 suites, 0
failed, 0 skipped**, including the three invariant campaigns (256 runs, 16,384 calls each,
zero handler reverts). The constructor ABI is nonpayable with nineteen static inputs
(address ×5, uint24 ×2, address ×4, bytes32, uint128 ×2, uint16 ×4, uint8). Build
configuration and vendored dependencies were left intact. No Slither, Mythril, fork or
deployment was run.
