# Oracle ABI and signing contract

The task's oracle callback and type declaration were cut off mid-word. No complete oracle ABI was supplied and the referenced explorer source was not accessible during this work. This project makes the following explicit, testable reconstruction. Confirm it against the actual Intake/oracle implementation **before launch**; a mismatch requires a source change and retest, not an attempt to accept arbitrary signed data.

Intake ABI:

```solidity
struct Callback { address target; bytes4 selector; }
function priceOf(bytes32 action, address paymentToken) external view returns (uint256);
function request(bytes32 action, bytes body, Callback callback, address paymentToken, uint256 price)
    external returns (bytes32 requestId);
```

The body is UTF-8 JSON encoded as `bytes`. Request IDs are nonzero and permanently unique within a gate, and returned synchronously; results arrive asynchronously. A synchronous callback during submission is rejected by the reentrancy guard and the pending-ID check. The Intake must consume the exact quoted price in the request call. Unused allowance is cleared; underpayment, fee-on-transfer assets, a failed request, and reused IDs revert atomically.

Callback ABI: `onOracleResult(bytes32 requestId, Attestation a, bytes signature)`.

Exact EIP-712 primary type (field spelling/order/types matter):

```text
OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreementBps,uint64 issuedAt,uint64 expiresAt)
```

The struct has exactly those fields. Dynamic `answer` is hashed when constructing the struct hash. Signatures are standard 65-byte `r || s || v`; OpenZeppelin ECDSA enforces low-s and valid recovery. The EIP-712 domain is:

| Field | Value |
| --- | --- |
| name | `IdentityMD Oracle` |
| version | `2` |
| chainId | `1` |
| verifyingContract | Configured `oracleVerifier`; initial assumption is Intake |

`questionHash = keccak256(bytes(decodedJsonQuestion))`, not the hash of the escaped string or complete JSON body. The boolean answer is exactly 32-byte `abi.encode(bool)`. The assumed boolean type code is **0**, configurable for future requests. No fallback for another domain, signer, schema, hash convention, or type is accepted. The two incompletely specified fields after quorum are reconstructed as `uint16 agreementBps`, `uint64 issuedAt`, followed by `uint64 expiresAt`.

The callback checks pending status, original Intake, chain, ID, question hash, answer type/length, signer and domain, panel size 30/quorum 20, agreement 6667–10000 bps, nonzero block and panel job hashes, ordered block bounds no later than the current block, issue time between submission and now, and an unexpired validity interval of at most 900 seconds. Block hashes/evidence are trusted signed statements; the callback does not replay panel work or verify historical state. The agreement threshold (ceiling of two thirds) is an explicit conservative assumption, separate from the stated panel quorum.

A true answer stores `min(now + 300, expiresAt)`; false releases the user's active request slot. No callback transfers tokens, reads NFT ownership, builds JSON, or calls PoolManager. `OracleGasTest` submits in setup and invokes the callback with a 199,999 gas cap in a separate test transaction. The signature fixture is constructed independently of the production hashing library.

Configuration is snapshotted by version: changing Intake/signer/domain cannot replace the authentication conditions of an already-pending request. Old results may be recorded, but the old approval cannot execute after a configuration update. Users can clear such requests immediately.
