# CabalCoin

Foundry project for a CABAL/IMD Uniswap v4 launch on Ethereum mainnet. CABAL is a plain ERC-20; a signed IdentityMD panel decision gates each trade in the designated pool. No transactions have been broadcast.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, via IR, `bytecode_hash = "none"`. No FFI, filesystem cheatcode permissions, environment-dependent tests, submodules, or download-on-build dependencies. Dependencies are ordinary files in `lib/`, with commit IDs and upstream locations in [docs/dependencies.json](docs/dependencies.json). The verifier must supply the pinned compiler and Foundry. Tests use a real local v4 PoolManager and mocked Intake/signatures, with both currency orderings and CABAL-only seeding.

## Contracts and flow

- `CabalCoin`: no constructor arguments, 18 decimals, exactly 1,000,000,000 CABAL minted to its deployer. Standard transfers/allowances. No owner, mint, tax, pause, or upgrade path.
- `CabalHook`: constructor `(IPoolManager manager, address initialOwner, IERC20 pair, address factory)`. Binds one pool at initialization by `factory`, infers CABAL as the currency other than IMD, and accepts fee **12500** and tick spacing **60**. Only PoolManager can call the enabled callbacks. Only the bound `CabalGate` can swap. Seeding, adding/removing liquidity, donations, and LP fee collection have no gate restriction.
- `CabalGate`: constructor `(CabalHook launchHook, address initialOwner, Config initialConfig)`. Deploy after pool initialization. One outstanding pending/approved request per account. Buys/sells are exact input. The hook's gate binding is owner-only and **one time**.
- `QuestionBuilder`: deployed by the gate, immutable and stateless. Validates UTF-8, permits at most 280 Unicode scalar values in the reason, escapes JSON strings and control characters, bounds the decoded question to 2000 characters, and uses fixed definitions under 512 characters each.

The user first approves the gate to spend the oracle request price, then calls `submitBuyRequest(imdAmount, reason)` or `submitSellRequest(cabalAmount, reason)`. The gate queries `Intake.priceOf(action, IMD)`, pulls exactly that price, grants an exact temporary approval, calls `request`, and clears the approval. Submission does **not** escrow the trading principal. The emitted request body contains all panel settings and a hash of the decoded UTF-8 question.

An authenticated `onOracleResult(id, attestation, signature)` records approval or rejection only. A true decision permits execution for up to five minutes, capped by attestation expiry. No tokens move in this callback. See the full wire protocol and assumptions in [docs/ORACLE.md](docs/ORACLE.md); the assignment's attestation declaration was truncated.

Before execution the requester must call `setSlippageLimit(id, minimumOutput)` with a nonzero minimum. This preserves the specified one-argument `executeBuyRequest(id)` and `executeSellRequest(id)` entry points. Only the requester can set a minimum or execute, and each request executes at most once. Minimum output is **net of the sell fee**. Failed execution rolls back fees, trades, approval consumption and ledger changes, allowing retry within the deadline.

A request without a result can be cleared by its requester at exactly one hour using `clearRequest(id)`. Expired approvals and requests invalidated by configuration changes can also be cleared. The Intake charge purchases oracle work and is **not refunded** by this project. No principal is locked while waiting.

## Swap economics

The pool's 1.25% LP fee is separate from the hook's 0.5% IMD fee. For a buy, `imdAmount` means IMD input to the pool; the gate additionally pulls the 0.5% fee. For a sell, `cabalAmount` is the input; the fee is deducted from gross IMD output. Each 0.25% leg is `floor(IMD_volume / 400)` in minor units, so total charged is twice that number. Trades smaller than 400 minor units accrue no hook fee. At most two minor units of nominal fee are lost to rounding.

After every successful swap, half the fee is transferred to `0x000000000000000000000000000000000000dEaD` (a sink transfer, not an ERC-20 supply burn). The other half is deposited as **actual hook-owned v4 liquidity**, not donated to existing LPs. IMD is deposited single-sided just outside the current price: ten tick intervals above the next tick boundary when IMD is currency0, or below the current grid boundary when it is currency1. These positions become active if price enters their range. This avoids an extra, unapproved balancing swap. It does not promise immediately active or full-range liquidity.

Protocol positions have no withdrawal, recovery, or ownership-transfer function. Anyone can call `compound(lower, upper)` on an existing hook position to collect and reinvest its accrued fees. Principal remains permanently in those positions. Any CABAL fees collected are also reinvested single-sided. Token rounding residue stays in the hook for future deposits. Tiny deposits that cannot buy one liquidity unit accumulate as residue. `ProtocolLiquidityAdded` logs identify the ranges for keepers.

The gate prefunds PoolManager before swapping, collects output, then calls `hook.finishSwap()` inside the same unlock. The hook charges from the gate's settled balance and adds liquidity. Neither swap callback transfers funds out of PoolManager. All gate and hook currency deltas settle to zero before returning. This also works on a fresh manager holding only seeded CABAL. There are no custom return deltas or hook fee exemptions for swaps. See Uniswap's [callback model](https://developers.uniswap.org/docs/protocols/v4/concepts/hooks) for the underlying API.

## Limits, accounting and trust

Owner configuration covers Intake, action, IMD address, signer, EIP-712 verifier, boolean type code, observation window (1–24 hours), maximum input size per side, and maximum price movement (1–5000 bps). Initial observation window is one hour. The response timeout remains one hour and execution lifetime remains five minutes. Every configuration update creates a version and invalidates prior execution approvals; callbacks authenticate with the original version. Ownership uses two-step transfer. The owner cannot withdraw user funds or directly approve a request, but can choose a signer that approves future requests and can prevent trading through limits/configuration.

**IMD is owner-settable through `CabalHook.setIMD` before pool binding, and cannot change to a different currency afterward.** `configure` validates IMD against the immutable pair. A different IMD asset requires a new pool/hook/gate, not silently reinterpreting an existing approval. The constructor parameter provides the initial IMD address. Only ordinary non-rebasing, non-taxed ERC-20 assets are supported; received amounts and manager settlements are checked exactly.

The question includes size/impact limits, requester, amount, an optional identity.md NFT signal, and the quoted reason marked as untrusted text. Sell questions additionally include wallet holdings/share, indicative current price, gate-recorded average cost and first-buy time. NFT lookup failure is “unknown” and never blocks a request.

Impact is the symmetric relative marginal-price change `1 - min(priceA, priceB)/max(priceA, priceB)`. The submission estimate uses current active liquidity and excludes tick crossings; it is an informational spot estimate, **not a manipulation-resistant value oracle**. The panel must assess depth independently. Execution enforces actual movement, drift from the request snapshot before and after the swap, full input consumption, and the user's minimum output. Price is limited to ticks ±880000 to leave space for POL. The panel's signed opinion and the user's minimum remain essential.

Recorded average cost includes IMD spent on gate buys plus hook fees; it excludes oracle fees. First-buy time resets after the recorded position is exhausted. Plain transfers cannot be intercepted: received CABAL has unknown basis, observed balance reductions proportionally reduce tracked units/cost, and sells consume tracked units first. A transfer out and back between observations is invisible. The question explicitly states these limitations; the ledger is not proof of continuous ownership or tax accounting.

Standard token transfers also mean **other pools and OTC trades cannot be forced through this gate**. The guarantee is for swaps in this designated hooked pool. Globally gating every token movement would conflict with the required plain ERC-20.

## Deployment and operation

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for addresses, constructor parameters, salt mining, initialization order, and launch responsibilities; see [docs/SECURITY.md](docs/SECURITY.md) for the local review and remaining integration work. This assignment delivers local code and tests. Mainnet ABI/domain verification, fork rehearsal, independent review, and deployment remain operator responsibilities.
