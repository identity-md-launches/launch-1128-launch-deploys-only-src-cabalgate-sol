# CabalGate launch adaptation

This is a contracts-only launch of **CabalGate** against the existing hook at
`0xf41b6ff942a082c0d320a0c151310ac2a922a0c0`. The gate creates its own
QuestionBuilder and ImpactEstimator. CabalHook and CabalCoin source is unchanged;
neither is part of this launch. No transactions were broadcast.

## Changes and reasons

| Files | Change and requirement |
| --- | --- |
| `src/CabalGate.sol` | Replaced the constructor's Config tuple with the thirteen static arguments in the brief's order. The constructor remains nonpayable, assigns ownership to the explicit initialOwner, builds Config with oracleVerifier equal to this gate and boolAnswerType equal to zero, and calls the original validation. Both helpers are still created internally. Removed a stale comment about the request body's old validity. |
| `src/QuestionBuilder.sol` | Changed only the requested validForSeconds from 900 to 3900 to fix reproduced audit finding `81a5272f…`. This covers REQUEST_TIMEOUT (3600) plus APPROVAL_WINDOW (300). The gate's deadline, approval cap, maximum attestation validity and all callback/execution checks are unchanged. |
| `test/CabalFixture.sol`, `test/HookBinding.t.sol`, `test/Launch.t.sol` | Updated existing deployment calls through a shared helper using the flat constructor. The helper uses Foundry's artifact deployment to avoid embedding gate creation code in every inheriting test contract. Historical token/hook launch tests remain local regression tests; their comments distinguish them from this gate-only launch. |
| `test/GateLaunch.t.sol` | Added CREATE2 factory rehearsal with the exact thirteen manifest words, a separate explicit owner, and mocked code at the supplied hook, Intake and IMD addresses. Covers every configured value, self-verifier, boolean type, helper creation, constructor validation, missing dependencies, initialized hook, owner authority, and successful one-time hook binding followed by refusal of a second gate. Scans gate and both helpers for forbidden opcodes and enforces runtime/init-code size limits. Existing tests still exercise the actual hook's binding implementation. |
| `test/OracleLatency.t.sol` | Regression reads the request body's validity, signs at submission, delivers after 899, 900 and 3599 seconds under the mock Intake's 200,000-gas callback limit, and executes successfully at the last second of a full five-minute approval. |
| `test/Oracle.t.sol`, `test/QuestionProperties.t.sol` | Updated only request-body validity assertions to 3900; existing expiry, replay, signature, fee and limit checks remain. |
| `test/OracleSigner.t.sol` | Reproduces the informational ERC-1271 limitation with a registry that accepts the signature while the gate rejects it. Pins the audited ECDSA-only model rather than changing the gate's verification behavior. |
| `README.md`, `docs/DEPLOYMENT.md`, `docs/ORACLE.md`, `test/README.md` | Documented the flat ABI, supplied arguments, gate-only deployment, existing hook owner's handoff, validity fix, new coverage, and ECDSA signer requirement. Replaced obsolete instructions to launch the token and hook again. |

The initial constructor adaptation preserved the original gate runtime. This
review revision adds the submission binding check described below. The oracle
struct, type string, domain, callback/execution logic, fees, limits, getters and
owner configuration behavior remain unchanged. The earlier reproduced validity
fix in QuestionBuilder is retained.

## Imported audit disposition

1. **`81a5272fa2871af4004dfb8c074194087e30278ff143062499f9db43419e7fe3` — short validity: reproduced and fixed.**
   Before changing QuestionBuilder, the new latency regression failed at 899
   seconds: approvedUntil was 1800000900 instead of 1800001199. The old body
   supplied an expiry that left one second to execute. Requesting 3900 seconds
   lets an attestation issued no earlier than submission remain valid throughout
   any on-time delivery and the ensuing five-minute approval. It is below the
   existing one-day sanity bound. Expired attestations are still rejected,
   shorter signed expiries still cap execution, and callbacks at the one-hour
   request deadline still fail. No refund or retry guarantee is added.

2. **`e72f4f85ca79f44eb1f7c5e34f7e5a3be99e93c11fa3430378cf890c159fed15` — initial pool depth: historical observation, no code change.**
   The exact mainnet snapshot at block 26145229 was not independently reproduced
   in this offline rehearsal. The imported audit reports approximately 28.35 IMD
   as the largest buy admitted by the 300 bps cap, with sells refused until price
   enters seed liquidity. These are historical audit numbers, not verified
   current quotes. The requested 300/500 bps limits are preserved. Existing
   local tests cover one-sided liquidity and impact/drift enforcement.

3. **`0f53ff5e29f06528143b06d176f30465f381db626858bbf130024e25198f3c74` — deployment size: reproduced and covered.**
   The original artifact has 23,630-byte runtime and 36,645-byte creation code.
   The constructor-only adaptation retained that runtime. This revision's
   necessary submission binding check adds 337 bytes: runtime is now 23,967
   bytes (609 below EIP-170); creation code is 36,970 bytes, or 37,386 including
   all thirteen ABI words, below 49,152. The rehearsal scans CabalGate, QuestionBuilder and
   ImpactEstimator, skipping PUSH data, for DELEGATECALL, CALLCODE and SELFDESTRUCT.

4. **`e710a893042eac0489270b56e9bdb1dfb8216395a448a1f29b13aeb0a79128dc` — dependency state: reproduced and covered.**
   Factory creation fails with absent hook, Intake or IMD code, or an
   uninitialized hook. Populating the supplied addresses with local mocks makes
   the exact arguments succeed. The mock returns the supplied live pool key,
   PoolManager, CABAL and IMD and accepts the resulting gate only once from its
   own owner. This tests the launch prerequisites without claiming a fresh
   mainnet bytecode, ownership, liquidity or unbound-gate verification.

5. **`814c193f1ec1486f222d3c795168f18aeea6e261505376d29a4ea2b5a269364b` — ERC-1271: reproduced informational limitation, preserved.**
   A valid registry response does not make its underlying key recover to the
   registry address. The supplied launch signer is an ECDSA key according to the
   imported audit, so this is not a failing path for the approved launch.
   The specific requirement to preserve the gate's audited verification behavior
   takes precedence over adopting the background reference's broader signer
   model. Operators must configure an attester key, not a registry. This
   adaptation does not claim ERC-1271 support.

6. **`272e6271154f7956efa4697043d4d3618f736041b4dd7bd94f102428963d288d` — owner powers: confirmed intended trust assumptions, preserved.**
   Existing tests demonstrate that configure invalidates an approved request
   and permits clearing it without refund. The owner can select a signer/Intake,
   change limits to prevent submissions, and invalidate earlier executions.
   Ownership remains two-step; renunciation freezes configuration. These are
   documented powers, not permission bypasses to remove.

## Review revision

**`0c508e6b061be4b239367a1ad8dbc6becdcaa49dcccffaf4540413867f9f5da2`
— unbound hook fees: reproduced and fixed.** The supplied proof, copied unchanged
to `test/scratch/Proof_0c508e6b061b.t.sol`, failed on the starting source with
`next call did not revert as expected` (594,451 gas). The new regression tests
also failed for both buys and sells in both currency orderings before the fix.

| Files | Revision and reason |
| --- | --- |
| `src/CabalGate.sol` | Added `if (hook.gate() != address(this)) revert InvalidConfig();` at the start of `_submit`, after the existing chain check. Both submission paths now refuse an unbound hook or one bound to a different gate before building a question, querying the Intake or moving funds. This is the only production-code change in this revision. |
| `test/HookBinding.t.sol` | Added buy and sell regressions using real local CabalHook and PoolManager instances, inherited by the reverse-currency suite. Assert no fee, allowance consumption, Intake request or occupied request slot before handoff or for a different gate. After the correct one-time binding, the same request pays exactly 0.5 IMD and completes approval and execution; a second binding still reverts. |
| `docs/DEPLOYMENT.md` | Documented the enforced handoff prerequisite and the current Intake/signer/price trust boundary for submitters. |
| `.imd-responses.json`, `ADAPTATION.md` | Recorded every review finding's disposition and the revision's reproduction, change and validation evidence. |

The constructor still allows deployment before the existing hook owner's
separate handoff. No constructor binding check was added: submission now prevents
the fee loss even if that handoff is skipped or a different gate is selected.
CabalHook and CabalCoin remain unchanged, and neither is a launch target.

**`f63ff0a91b0e35931684c674b90078310ef1ce2ea1068ee755b1f65658953e22`
— Intake price: confirmed owner trust assumption, preserved.** The scratch
`IntakePriceTrustTest` configures an Intake quoting ALICE's entire IMD balance;
her subsequent submission pays that quote in full. The same test confirms ALICE
cannot call `configure`. This is the existing owner power, not a permission
bypass. No price cap or configuration restriction is introduced. The operator/UI
should display the current Intake, signer and price; users should approve only
the intended request price and, separately, the trade input plus any buy fee.

## Launch handoff and validation

The manifest is written by the next assignment. The existing `launch.json`
still describes the previous token/hook launch and **must be replaced before
launch** with an `evm_contracts` manifest containing only CabalGate and the
arguments in the brief (also transcribed in `docs/DEPLOYMENT.md`). It was not
edited here. No owner address was guessed; the constructor uses `$owner`.
After deployment the existing hook owner calls `hook.setGate(gate)` once.

Build configuration and vendored dependencies were left intact. Validation uses
the project's own Foundry profile without network access or environment inputs.
Revision validation: `forge build` passed; `forge test` passed **153 tests in 24
suites**, with zero failures or skips. Of these, 151 tests in 22 suites are
delivered; the other two are the unchanged supplied proof and the Intake-price
trust reproduction in scratch. Coverage includes factory/runtime/opcode checks,
the four new handoff cases, all three isolated latency cases, live signing
vectors, fuzz properties, and both invariant campaigns (256 runs and 16,384
calls each, zero handler reverts). `git diff --check` passed. Artifact inspection
confirmed the size bounds above and the unchanged thirteen-word nonpayable
constructor ABI. `.imd-responses.json` contains all eight finding responses.
No Slither, Mythril, live fork, deployment or funded-wallet operation is claimed.
