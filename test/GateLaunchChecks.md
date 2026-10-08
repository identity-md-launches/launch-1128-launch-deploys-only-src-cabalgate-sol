# Gate-only test verification

The production constructor already has the thirteen flat arguments. Tests reuse the initialized-hook mock and existing dependencies; the added suites do not deploy CabalHook or CabalCoin. The existing launch fixture was extracted into an abstract base without changing its assertions.

## Commands and results

Build artifacts and caches were placed under disposable `test/scratch/` using the process variables `FOUNDRY_OUT=test/scratch/out` and `FOUNDRY_CACHE_PATH=test/scratch/cache`. No configuration file or shared test environment was changed.

| Command | Result |
| --- | --- |
| `forge build` | Passed; Solidity 0.8.26. Forge lint warnings remain. |
| `forge test --match-path 'test/GateFactoryEdges.t.sol'` | 8 passed, including 256 constructor fuzz cases. |
| `forge test --match-path 'test/invariant/GateOnlyRequests.t.sol'` | Both invariant functions and the deterministic handler test passed. Foundry grouped the invariants into one campaign: 256 runs, 16,384 calls, zero unexpected reverts. |
| `forge test` | 157 passed across 24 suites; zero failed or skipped. Includes the existing trading/accounting invariants for both currency orderings. |
| `git diff --check` | Passed. |
| `command -v aderyn` | Exit 1: unavailable on this task's PATH; analysis not run. |

The supplied protocol vector pins the digest, signature recovery and callback selector. Because the generic vector uses a Sepolia domain and an array answer, it exercises the production digest library. Actual gate callbacks are exercised separately on mocked chain 1 with boolean answers and a 200,000-gas callback limit. No fork, network, FFI or extra dependency is needed by the delivered tests.

## Static analysis

`forge build --skip test --skip script --build-info --ast` passed, with output/cache under `test/scratch/slither-out` and `test/scratch/slither-cache`.

`slither . --foundry-ignore-compile --foundry-out-directory test/scratch/slither-out --foundry-build-info-directory test/scratch/slither-out/build-info --filter-paths 'lib/|test/|script/' --exclude-dependencies --json test/scratch/slither.json` could not analyze the generated `foundry-pp/DeployHelper106.sol` path. A direct CLI attempt also hit the adapter's attempt to install solc-select into a read-only directory.

Analysis then completed through the installed Slither Python API, using `CryticCompile(Solc('src/CabalGate.sol'), ...)` with the already-installed `/home/debian/.svm/0.8.26/solc-0.8.26`, the project's remappings, optimization at 200 runs, via-IR and Cancun. Supplying the `Solc` platform object bypassed those adapter issues. The executed command was `/home/debian/.local/share/pipx/venvs/slither-analyzer/bin/python test/scratch/run_slither.py`. All installed detectors were registered; dependency paths were filtered. Its local script, logs and raw JSON are disposable scratch artifacts.

Slither reported 35 alerts: 20 medium, 11 low and 4 informational. Review of the alerts:

| Alert group | Count | Assessment |
| --- | ---: | --- |
| Reentrancy/state/event ordering | 8 | No demonstrated bypass: submission/execution/compounding entry points have reentrancy guards; callbacks authenticate the pool manager; the gate consumes its unlock capability before token interaction. Read-only getters can expose intermediate state. This assessment depends on the existing pool manager and token trust model. |
| Unused return values | 10 | Unused tuple components are intentionally irrelevant to these reads; liquidity settlement uses the returned net balance delta. Compounding returns empty callback data. |
| Strict equality | 5 | Zero sentinels and zero-amount/zero-liquidity exits, rather than assumptions that externally mutable balances equal fixed totals. |
| Division before multiplication | 3 | Intentional per-leg fee floors and tick-grid alignment, including the negative-tick adjustment. Existing economic tests exercise fee rounding and settlement. |
| Timestamp comparisons | 4 | Required request/approval deadlines and signed validity checks; boundary tests cover expiry. |
| Missing zero check on hook initializer | 1 | The recorded initializer is informational; it grants no permission. The new launch reuses an initialized hook. |
| Complexity, low-level call, event indexing | 4 | Informational. The NFT query is a gas-capped static call with length/success checks and an `unknown` fallback. |

No additional defect was confirmed from these alerts, and no alert was suppressed in production code. These results are not proof of security.

## Reported defect

`.imd-findings.json` reports the unchanged launch manifest: `kind` is `univ4_hook`, the hook is `CabalHook`, the token is `CabalCoin`, and there is no `contracts` list containing CabalGate. A local Python assertion requiring `evm_contracts` with exactly one CabalGate entry failed. The expected thirteen constructor words are recorded in the finding. This manifest cannot represent the requested gate-only launch; changing it is outside this tests-only assignment.
