# Oracle ABI and signing contract

The assignment's attestation declaration was truncated. The first round reconstructed it from the brief; the revision of 2026-10-08 replaced the reconstruction with the live IdentityMD Oracle wire format, read from the deployed Intake and from two attested requests of the service. Everything below was verified against those sources, and `test/OracleLiveVector.t.sol` pins the real payload and signature.

## Sources

| Source | What it established |
| --- | --- |
| Intake `0x1397434cd35e8a9C8aC312A61D3A285EB31dea56` runtime (Ethereum mainnet and Robinhood Chain 4663, same address) | Selectors `request(bytes32,bytes,(address,bytes4),address,uint256)` = `0x380c2cda`, `priceOf(bytes32,address)` = `0x51102885`, `callbackGas()` = 200000, `MAX_BODY_BYTES()` = 16384, `priceOf(bytes32("oracle.request@oracle-1"), IMD)` = 0.5 IMD. Its own EIP-712 domain is `IdentityMD Intake` v1, used for price quotes, not for attestations. |
| Mainnet tx `0x4addfc15…c7210d` (block 26142980) | A `request` with body `{"v":1,"question":…,"chainId":1,"window":{"hours":24},…}`; event `Requested(bytes32 indexed id, address indexed requester, bytes32 indexed action, bytes body, address target, bytes4 selector, address token, uint256 price)`; `id = keccak256(abi.encode(block.chainid, intake, nonce))`. |
| Robinhood Chain tx `0xf3652710…caaee3` (block 82798692) | The writer `0x3d3C0Df7…25CB` calling `complete(bytes32 id, uint8 status, bytes32, string url, bytes payload)`; the Intake forwarding `payload` to the consumer with the callback selector prepended. |
| `GET https://api.imd.fun/oracle/requests/e14151e8-054b-49c0-9139-e63c28270657/attestation` | The typed data (primary type, domain, signature, signer `0x5598Aa91…2982`). |
| `GET https://api.imd.fun/oracle/requests/<id>` for both requests | The `questionHash` convention (below). |

## Intake ABI

```solidity
struct Callback { address target; bytes4 selector; }
function priceOf(bytes32 action, address paymentToken) external view returns (uint256);
function request(bytes32 action, bytes body, Callback callback, address paymentToken, uint256 price)
    external returns (bytes32 requestId);
```

The body is UTF-8 JSON as `bytes` (at most 16384 bytes). The Intake pulls exactly `price` of `paymentToken` from the caller and returns a nonzero id that is unique per chain and Intake. Results arrive asynchronously: the oracle writer calls the Intake, which calls `callback.target` with `callbackGas` (200,000) and calldata

```text
callback.selector ++ abi.encode(bytes32 requestId, Attestation attestation, bytes signature)
```

so the gate's callback is `onOracleResult(bytes32 requestId, Attestation calldata a, bytes calldata signature)`. A synchronous callback during submission is rejected by the reentrancy guard and the pending-id check. Unused allowance is cleared; underpayment, fee-on-transfer assets, a failed request and reused ids revert atomically. The failed mainnet request (3 of 4 members agreed, quorum 4) was completed with status 2 and no callback: a request the panel cannot decide is never delivered, and the gate's one-hour timeout is the only exit.

## Attestation

```solidity
struct Attestation {
    bytes32 requestId;     // the oracle's own request id (a UUID left-aligned in bytes32), NOT the Intake's id
    uint256 chainId;       // the chain the question is about: 1
    bytes32 questionHash;  // see below
    uint8   answerType;    // 0 for "bool"
    bytes   answer;        // abi.encode(bool)
    uint256 figure;        // 0 for bool answers
    uint64  fromBlock;     // the window the oracle pinned from "hours"
    uint64  toBlock;
    bytes32 blockHash;     // hash of toBlock
    bytes32 panelJobId;    // UUID left-aligned
    uint16  panelSize;
    uint16  quorum;
    uint16  agreed;        // members who gave the signed answer, a count
    uint64  issuedAt;
    uint64  expiresAt;     // issuedAt + validForSeconds
}
```

EIP-712 primary type (spelling, order and types matter):

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)
```

Domain:

| Field | Value |
| --- | --- |
| name | `IdentityMD Oracle` |
| version | `2` |
| chainId | the request body's `consumer.chainId` (1 here) |
| verifyingContract | the request body's `consumer.verifyingContract`: the gate itself by default (`Config.oracleVerifier`, zero means this gate) |

The live consumer on Robinhood Chain declared itself as the verifying contract and the service signed for that domain; this gate does the same. Signatures are 65-byte `r || s || v`; OpenZeppelin ECDSA enforces low-s and valid recovery.

### questionHash

`keccak256` of the request's semantic fields serialised as JSON with keys sorted, no whitespace and raw UTF-8, with the window resolved to blocks:

```text
{"answerType":"bool","chainId":1,"definitions":{…sorted…},"evidence":"panel","question":"…","v":1,"window":{"fromBlock":F,"toBlock":T}}
```

`panelSize`, `quorum`, `validForSeconds` and `consumer` are not hashed. `definitions` is present whenever the request declared any; this project always does. Both live requests reproduce exactly under this rule (`test_liveQuestionHashIsCanonicalKeccak` for the one with definitions). Because `F` and `T` are chosen by the oracle, the gate cannot know the hash at submission. It therefore emits the body already in canonical form, stores the JSON-escaped question in a code blob (`DataStore`, the SSTORE2 pattern) and recomputes the hash in the callback from that blob, the fixed definitions and the attested window. Control characters are refused in the reason because JSON serialisers escape them differently; `"` and `\` are escaped identically everywhere, and non-ASCII is left raw by the service.

### Binding and replay

The signed `requestId` is the oracle's id, so it does not identify the gate's request. The binding is the signed `questionHash` of the request's own stored question (which names the requester, amount, limits and reason), together with `msg.sender == intake` for a pending id. Each oracle attestation id is consumed once (`attestationUsedBy`), so a delivered attestation cannot be presented again for another pending request even if the Intake writer were compromised; it also cannot be presented for an older request because `issuedAt` must not precede that request's submission.

## Callback checks

Pending status and the original Intake of the request's config version; chain 1 and before the one-hour deadline; a nonzero, unused oracle id; `chainId == 1`; the configured boolean type code and a 32-byte answer; `fromBlock <= toBlock <= block.number`; nonzero `blockHash` and `panelJobId`; `panelSize` and `quorum` equal to the configured request parameters (30/20 initially, owner-settable because a service-side change would otherwise strand every request); `quorum <= agreed <= panelSize`; `issuedAt` between submission and now plus a 5-minute clock tolerance; `expiresAt` in the future, after `issuedAt`, and at most one day later; the recomputed `questionHash`; then the signer. Nothing else: no token transfers, NFT reads, JSON building or PoolManager calls. `OracleGasTest` delivers an attestation for the longest accepted question with a 199,999 gas cap; the mock Intake otherwise delivers with exactly 200,000 gas in the live calldata shape.

A true answer stores `min(now + 300, expiresAt)`; false releases the user's active request slot. Configuration is snapshotted by version: changing Intake, signer, verifier or panel parameters cannot replace the authentication conditions of an already-pending request, and old approvals cannot execute after a configuration update (the user clears them).

## What remains an assumption

- The `questionHash` rule and the callback shape were observed, not read from published source. A change on the service side shows up as every request staying pending until the one-hour timeout; the signer, verifier, Intake and panel parameters are owner-settable, the struct and the hash rule are compiled in.
- The oracle honours the body's `panelSize`/`quorum` (both live requests echo them). If it clamps them, set `Config.panelSize`/`quorum` to what it actually attests.
- A request without a decision (quorum not reached) is never delivered; its 0.5 IMD is not refunded by anyone in this design.
