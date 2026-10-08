# CabalGate-only launch

Target: Ethereum mainnet, chain ID 1, Cancun. The factory deploys **only `src/CabalGate.sol:CabalGate`**. Its nonpayable constructor creates QuestionBuilder and ImpactEstimator. CabalHook, CabalCoin, the pool and its liquidity already exist; do not deploy or initialize them again.

The old `launch.json` describes the earlier token/hook launch and is not suitable for this launch. This implementation assignment leaves manifest writing to the separate manifest step, which must replace it with an `evm_contracts` manifest containing only CabalGate.

The flat constructor takes these arguments in order. `$owner` is resolved by the launch system; it is not the factory and no wallet is supplied by this adaptation.

| Argument | Type | Manifest value |
| --- | --- | --- |
| hook | address | `0xf41b6ff942a082c0d320a0c151310ac2a922a0c0` |
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

The constructor builds Config with `oracleVerifier = address(this)` and `boolAnswerType = 0`. It uses the existing validation and reads initialized(), poolManager(), cabal(), poolKey() and imd() from the hook. Intake and IMD must have code. The gate creates both helpers and is fully configured without initialization calls. The hook retains its own owner, independently of the gate's `$owner`.

After deployment, the **existing hook owner** calls `hook.setGate(gate)` once. Check `gate.hook()` equals the hook and `gate.cabal()` equals the hook's CABAL first. The supplied audit recorded CABAL as `0x450e5910DEcEe15c3AC056E3ed66Cb5ea3Dd33BE` and the hook owner as `0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`; these are historical audit observations, not a fresh on-chain verification. The hook must still be unbound. Once bound it rejects a second gate. This owner call is the requested existing-hook handoff, not a gate initializer or a call performed by the factory.

Both buy and sell submissions revert with `InvalidConfig` until `hook.gate()` equals this gate. This check runs before any oracle payment or request creation, including when the hook has permanently selected a different gate. Enable submissions only after confirming the binding.

`test/GateLaunch.t.sol` rehearses the exact static arguments with mocked code at the supplied dependency addresses, CREATE2 deployment, explicit gate ownership, both helper deployments, constructor validation, and one-time hook binding. The existing integration tests continue to exercise the real hook and PoolManager locally. Local tests do not establish today's live pool state. No transactions are broadcast by this assignment.

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
