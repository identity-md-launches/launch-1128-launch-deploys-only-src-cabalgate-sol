# Deployment parameters and responsibilities

Target is Ethereum mainnet, chain ID 1, Cancun support. No PoolManager address is hardcoded anywhere in the project. The network deployer supplies an authenticated `IPoolManager` instance for the target chain (`$poolManager` in its separately generated manifest).

Provided addresses, not independently verified against live bytecode during this assignment:

| Parameter | Mainnet value from brief |
| --- | --- |
| IMD pair/payment token | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Intake | `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56` |
| Oracle signer | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |
| identity.md NFT | `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` |
| Burn sink | `0x000000000000000000000000000000000000dEaD` |
| Initial action | `bytes32("oracle.request@oracle-1")`, UTF-8 padded with zero bytes, not keccak256 |
| Oracle domain verifier | the gate itself (`Config.oracleVerifier = 0` selects it), declared in the body's `consumer` |
| Boolean type code | 0, as attested by the live service |
| Panel size / quorum | 30 / 20, owner-settable |
| Pool LP fee / tick spacing | 12500 / 60 |
| Hook flags | 8384 decimal / `0x20c0` |

`CabalGate.mainnetConfig(maxBuy, maxSell, impact, drift)` returns the default configuration with explicit operator-selected limits (`drift >= impact`). Size limits are raw minor units (CABAL is 18 decimals; verify IMD's actual decimals); no example economic cap is silently selected for mainnet. The observation window starts at 1 hour. Use a reviewed multisig for initial owner; owner transfer requires acceptance.

1. Verify chain ID, deployed PoolManager, IMD code/behavior/decimals and NFT ABI. The Intake ABI, callback calldata shape, attestation schema, domain, boolean type code and questionHash rule were verified against the live service on 2026-10-08 ([ORACLE.md](ORACLE.md), `test/OracleLiveVector.t.sol`); re-check them against a fresh attestation before launch, since they are observed behaviour, not published source.
2. Set the factory address that will actually call `PoolManager.initialize`, initial owner, IMD, pool fee/spacing, start price, seed ranges and seed amounts. A factory intermediary's address is different from an EOA's address. Before-initialize authenticates the immediate `sender` provided by PoolManager.
3. Build `CabalCoin` with no arguments. The factory receives exactly 1e27 units. It must deploy the token before creating the pool. The hook learns the token from the sorted `PoolKey`; no token placeholder is passed to the hook.
4. Encode `CabalHook` creation bytecode plus `(poolManager, initialOwner, IERC20(IMD), factory)`. Mine a CREATE2 salt for the **actual deployer**, this complete creation-code hash and flags `0x20c0`. `script/HookSaltMiner.sol` implements a bounded offline search and is exercised by the integration fixtures. It needs no environment variables or wallet. Verify the candidate is unused. Changing compiler, arguments, factory/deployer or bytecode changes the result.
5. The factory deploys the hook at that salt and initializes its pool in the same transaction. Sort CABAL and IMD by address; use fee 12500, spacing 60 and the deployed hook. The constructor validates address permission bits; `beforeInitialize` rejects other initializers, currencies without IMD, another pool, and unsupported parameters. An initialization callback prevents empty code at the predicted hook address from successfully answering initialization.
6. Seed through the factory's normal LP path. Seeding and factory LP fee collection/removal remain available. Choose a price within ticks ±880000. The estimator reaches liquidity on either side of a gap (it scans up to 32 bitmap words, about 8192 tick-spacings, per direction), so a CABAL-only seed outside the current tick and a later factory unwind leaving only protocol-owned liquidity both keep submissions possible in the direction that has liquidity; a direction with none is refused with `LimitExceeded`.
7. Deploy `CabalGate(hook, initialOwner, initialConfig)` after initialization. It creates its `QuestionBuilder`. Call `hook.setGate(gate)` as hook owner. This is irrevocable; check all getters and configuration first. A separate gate is necessary; the hook constructor cannot deploy it because the pool does not exist yet. If the launch system supports only token+hook deployment, arrange this post-initialization step explicitly. Swaps remain disabled until binding, while factory LP operations remain available.
8. Rehearse both buy and sell against production addresses on a mainnet fork, with genuine signing vectors and real token transfers. Also rehearse timeout, slippage failure, token-only seeding, and factory unwind/fee claims. The delivered tests do not substitute for these integration checks.
9. Obtain independent adversarial review. Verify source and runtime code on deployment, publish pool ID, addresses, constructor arguments, config version and permission flags, and hand operations to the nominated owner. This assignment does not authorize broadcasting or funded-wallet access.

Monitor `RequestSubmitted`, `OracleResult`, `RequestExecuted`, `Configured`, and `FeePaid`. Maintain oracle callback delivery/retry and alert on missing or expiring requests; a request that stays pending for an hour while `GET /oracle/requests/<id>` shows it attested means the wire format changed. UI must show non-refundable request cost, buy fee in addition to input, net sell minimum, reason visibility (no control characters, no « »), current limits, pending deadline, approval deadline and config invalidation. Users must approve principal separately for execution and pass their minimum output inline (`execute…(id, minimumOutput)`) or set it first. Do not default to a zero minimum.

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
