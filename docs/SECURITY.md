# Local security review

This is a local implementation review, not an independent audit. The supplied Ethereum and v4 security references were considered as checklists. Repository reference material did not authorize transactions or alter task scope.

| Area | Design and evidence |
| --- | --- |
| Hook permissions | Initialization, before-swap, after-swap only; address bits checked in constructor and tests. Disabled callbacks are not implemented. |
| Caller and pool identity | Every enabled callback and unlock callback requires PoolManager. Swap sender must be the bound gate. Initialization requires configured factory, pair, fee, spacing and a single pool. |
| Admission bypass | Gate has no arbitrary swap or arbitrary-call entry point. Unlock requires an execution capability, which is consumed before interaction. Hook exposes no swap function. Gate binding is one time. |
| Owner powers | Two-step ownership; versioned configuration changes invalidate older executions. Pair may be set only before initialization. Owner cannot withdraw POL or directly approve a pending request. Initial owner can choose a malicious gate, and gate owner can choose a malicious future signer; this remains a deployment/governance trust boundary. |
| Return deltas / NoOp | All return-delta flags false; zero custom before/after deltas and zero fee override. Actual v4 AMM deltas determine volume and output. |
| Settlement | Gate prefunds manager, performs full-input swap, takes output and pays hook; hook settles its own position deltas. Tests assert zero outstanding deltas, zero gate balances and zero temporary approvals. |
| Empty manager | CABAL-only seeds tested with both currency orderings. Hook never takes an unsettled fee directly from PoolManager. |
| Fee economics | Buy fee additional to input; sell fee deducted from output. Sink balance, actual hook position liquidity, locked principal, and conservation tested. LP fee stays 12500. |
| Reentrancy | OpenZeppelin guard covers submit/callback/execute/configure/clear and hook finish/compound. Request execution consumed before token calls; unlock capability consumed once. Adversarial Intake reentry tested. |
| Token behavior | SafeERC20 temporary exact approvals; exact receive/settle checks reject taxation or pretend-success transfers. Rebasing, ERC-777 and arbitrary malicious pair assets are not supported. |
| Oracle forgery/replay | Independent test signing implementation; mismatched ID/hash/type/chain/domain/signer, tampering, malformed booleans, invalid bounds, wrong panel/validity data, duplicate results and late results tested. Request IDs never reused. Production ABI/domain verification is still required. |
| Callback gas | Dedicated cap of 199999 gas. Callback only verifies and stores. No NFT reads, token calls, swaps or JSON construction. |
| Price protection | Required nonzero user minimum, actual price movement and snapshot drift checks, exact-input full-fill check, approval expiry. Removing liquidity between approval and execution cannot force an unacceptable fill. Spot estimates remain manipulable and must not be treated as value oracles. |
| Text injection | Raw reason is quoted and labeled untrusted. JSON escaping handles every control character and backslash/quote. UTF-8 validation rejects overlong, surrogate, truncated and out-of-range sequences. Tests cover injection-shaped text and 280 multibyte characters. Escaping cannot prove a panel is resistant to prompt injection. |
| Cost basis | Only successful gate purchases recorded. Failed trades rollback. Transferred-in assets are unknown; observed reductions reconcile proportionally; first-buy is not proof of continuous possession. Tests cover partial/full sale, repeated buys and transfers. |
| Liveness | Pending requests clear after one hour; expired or obsolete approvals clear. Intake price is spent, not refundable. Broken Intake or signer can prevent future approvals. Existing approvals are short-lived. |
| Code permanence | Token and hook runtime opcode checks exclude DELEGATECALL/CALLCODE/SELFDESTRUCT; EIP-170 size tests cover hook and gate. No upgrades, arbitrary owner calls or asset recovery paths. |
| Dependency availability | Vendored source with version/commit ledger; no submodules, network resolution, FFI or filesystem privileges required by builds/tests. |

Automated validation: Foundry build/test, property-based fuzzing of transfer conservation, attestation validation and buy/sell accounting (256 cases per fuzz test), real-PoolManager lifecycle tests, and callback gas-cap test. These are isolated tests independent of environment variables and live RPC. Forge's compiler/lint output was reviewed; generic lint warnings include intentional JSON concatenation, bounded casts, precise token balance checks, tick-grid rounding, and reentrancy-guarded external calls. No Slither/Mythril installation was available; neither those tools nor formal verification ran. A mainnet fork/genuine oracle signature test did not run because the production wire contract is incomplete in the supplied brief.

Remaining release responsibilities: reconcile the reconstructed oracle ABI and typehash with production, verify the supplied addresses and token behavior, fork-rehearse factory launch plus both trade directions, obtain independent adversarial review, verify deployed runtime/source, and operate callback delivery and monitoring. No deployment or funded-wallet operation was performed. Permanent POL is intentionally irrecoverable; review this economic choice before binding the pool.
