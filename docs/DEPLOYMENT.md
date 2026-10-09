# CabalGate-only launch

Target: Ethereum mainnet, chain ID 1, Cancun. The factory deploys **only `src/CabalGate.sol:CabalGate`**. Its nonpayable constructor creates QuestionBuilder and ImpactEstimator. CabalHook, CabalCoin, the pool and its liquidity already exist; do not deploy or initialize them again.

The manifest (`launch.json`) is written by the separate manifest step after this work is accepted; this tree carries none. The earlier manifest, which listed the thirteen-word constructor that parked launch 990, was removed.

The launch checks deploy the gate in an empty EVM with no chain state, so the constructor makes **no external calls and no code-length checks**: everything it needs arrives as a flat static word. `$owner` is resolved by the launch system; it is not the factory and no wallet is supplied by this adaptation. The pool words below are the live hook's values read on 2026-10-08.

| Argument | Type | Manifest value |
| --- | --- | --- |
| hook | address | `0xf41b6ff942a082c0d320a0c151310ac2a922a0c0` |
| poolManager | address | `0x000000000004444c5dc75cb358380d2e3de08a90` |
| cabal | address | `0x450e5910decee15c3ac056e3ed66cb5ea3dd33be` |
| currency0 | address | `0x450e5910decee15c3ac056e3ed66cb5ea3dd33be` |
| currency1 | address | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| fee | uint24 | `12500` |
| tickSpacing | uint24 | `60` |
| initialOwner | address | `$owner` |
| intake | address | `0x1397434cd35e8a9c8ac312a61d3a285eb31dea56` |
| imd | address | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| signer | address | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| action | bytes32 | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| maxBuyAmount | uint128 | `1000000000000000000000000` |
| maxSellAmount | uint128 | `10000000000000000000000000` |
| maxImpactBps | uint16 | `300` |
| maxDriftBps | uint16 | `500` |
| panelSize | uint16 | `30` |
| quorum | uint16 | `20` |
| windowHours | uint8 | `1` |

The constructor stores hook, poolManager and cabal as immutables (the `hook()` and `cabal()` getters are what `hook.setGate` checks), builds the PoolKey from currency0, currency1, fee, tickSpacing and `hooks = hook` (tickSpacing is an unsigned word because the launch ABI has no signed integers; it is narrowed to int24), creates QuestionBuilder and ImpactEstimator, and builds Config with `oracleVerifier = address(this)` and `boolAnswerType = 0`. It validates only what needs no chain state: non-zero addresses, `currency0 < currency1`, cabal is one of the two currencies and imd the other, tickSpacing in 1..2^23-1, and the numeric limits. The gate is fully configured without initialization calls. The hook retains its own owner, independently of the gate's `$owner`.

After deployment, the **existing hook owner** (`0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`, the owner of launch 953's hook) calls `hook.setGate(gate)` once. `setGate` compares only `gate.hook()` and `gate.cabal()`, never the pool key, and the binding is permanent; so before that call also recompute `keccak256(abi.encode(hook.poolKey()))` and compare it with the key built from the words above (`(0x450e…33be, 0xd34a…63b7, 12500, 60, hook)`), and confirm `hook.imd()` is the IMD word. A gate bound with a wrong key could never submit and could never be replaced. The hook must still be unbound (`hook.gate() == 0`). This owner call is the requested existing-hook handoff, not a gate initializer or a call performed by the factory.

Both buy and sell submissions revert with `InvalidConfig` until the hook reports this gate (`hook.gate()`), this CABAL (`hook.cabal()`), this IMD (`hook.imd()`) and exactly the stored pool key (`keccak256(abi.encode(hook.poolKey()))`). These checks run before any oracle payment or request creation, including when the hook has permanently selected a different gate. Enable submissions only after confirming the binding. The owner's later `configure` runs on the live chain and keeps the checks the constructor cannot make: Intake and IMD must have code and IMD must equal `hook.imd()`.

`test/GateLaunch.t.sol` rehearses the exact static words twice: first in an EVM where the hook, PoolManager, Intake, IMD and CABAL addresses have no code (what the launch checks do), then against a mock hook at the live address that reports initialized, poolKey, poolManager, imd, cabal and gate like the live one, covering the one-time owner binding, a request that succeeds once the gate is bound, and requests refused when any of those reads mismatch. The existing integration tests continue to exercise the real hook and PoolManager locally. Local tests do not establish today's live pool state. No transactions are broadcast by this assignment.

The initial amount ceilings are 1,000,000 IMD and 10,000,000 CABAL assuming their supplied 18-decimal units. They remain subject to the separate 300 bps impact and 500 bps drift limits. The imported audit reported much smaller effective trades in the seed state; see [ADAPTATION.md](../ADAPTATION.md) for the finding dispositions and owner trust assumptions. The configured signer is an ECDSA key, not an ERC-1271 registry. Configuration updates invalidate existing executions and do not refund oracle charges.

The gate owner can replace the Intake and signer. Submission pays the current Intake's full `priceOf(action, imd)` quote without a user-supplied cap, so a malicious owner-selected Intake can charge up to the user's available balance and allowance. Show submitters the current Intake, signer and quoted price. Users should approve only the intended request price, then separately approve the trade input plus any buy fee for execution.

Monitor `RequestSubmitted`, `OracleResult`, `RequestExecuted`, `Configured`, and `FeePaid`. Monitor oracle callback delivery (failed Intake callbacks are not retried) and alert on missing or expiring requests; a request that stays pending for an hour while `GET /oracle/requests/<id>` shows it attested means the wire format changed. UI must show non-refundable request cost, buy fee in addition to input, net sell minimum, reason visibility (no control characters, no « »), current limits, pending deadline, approval deadline and config invalidation. Users must approve principal separately for execution and pass their minimum output inline (`execute…(id, minimumOutput)`) or set it first. Do not default to a zero minimum.

Track `ProtocolLiquidityAdded` ranges and call `compound` to reinvest fees when economical. There is no keeper reward and no principal rescue path; keepers pay gas voluntarily or through the operator. All assets are ERC-20, so native ETH recipient rejection is not a fee path. A failing/paused/blacklisted IMD transfer causes atomic swap failure. Monitor permanent protocol liquidity, residue, and gate balances for unexpected donations.

Hook configuration record:

```json
{
  "hook": "BaseHook",
  "name": "CabalHook",
  "pausable": false,
  "currencySettler": true,
  "safeCast": true,
  "transientStorage": false,
  "shares": {"options": false},
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": {"license": "MIT"}
}
```

This is a minimal BaseHook-style implementation directly using v4 interfaces, not an inherited OpenZeppelin generator output. Settlement and checked narrowing are implemented in the contracts. The settings describe these behaviors; unused wrapper dependencies are not needed. Upstream v4-core carries its own BUSL-1.1/MIT licensing notices in vendored sources.
