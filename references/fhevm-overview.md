# FHEVM Overview

## Overview

Zama FHEVM is a coprocessor-based approach to Fully Homomorphic Encryption on Ethereum. Smart contracts do not perform FHE operations directly — the EVM dispatches encrypted inputs to an off-chain coprocessor that evaluates each operation and returns an opaque `bytes32` handle. The handle references the resulting ciphertext on the coprocessor but reveals nothing about the underlying plaintext on-chain.

The decryption path involves three components:
- **Gateway** — an on-chain bridge that receives decryption requests emitted by contracts.
- **KMS (Key Management Service)** — a threshold MPC layer that holds decryption keys and signs decryption responses; contracts verify the signature with `FHE.checkSignatures()`.
- **Relayer** — an off-chain service that routes decryption requests from contracts to the Gateway/KMS pair and delivers signed responses back on-chain.

All contracts using FHE must inherit `ZamaEthereumConfig`. Its constructor registers the FHE coprocessor address for the current chain; on an unsupported chain it reverts with `ZamaProtocolUnsupported()`.

---

## Complete Example

Annotated transaction flow for an encrypted store + user decryption round trip:

```
User                Contract             Coprocessor          Gateway / KMS
 │                      │                    │                     │
 │── set(enc, proof) ──>│                    │                     │
 │                      │                    │                     │
 │                 fromExternal()            │                     │
 │                 verifies ZK proof         │                     │
 │                 → internal handle h1      │                     │
 │                      │                    │                     │
 │                 FHE.allowThis(h1)         │                     │
 │                 FHE.allow(h1, user)       │                     │
 │                 _value = h1              │                     │
 │                      │                    │                     │
 │── getHandle() ───────>│                   │                     │
 │<─ h1 (bytes32) ───────│                   │                     │
 │                      │                    │                     │
 │                                  (user sends h1 + EIP-712 signed keypair to Gateway)
 │                      │                    │                     │
 │                      │                    │──── verify ACL ─────>│
 │                      │                    │     (h1, user)       │
 │                      │                    │                     │
 │                      │                    │<── re-encrypted val ─│
 │                      │                    │  (with user's ML-KEM key)
 │                      │                    │                     │
 │<── user decrypts locally ──────────────────────────────────────────
```

Key invariants:
1. The coprocessor never writes plaintext to L1 — only `bytes32` handles appear on-chain.
2. Handles are opaque: two handles for equal plaintexts are not equal — never compare handles directly.
3. ACL grants determine who may request decryption; without a grant, the Gateway rejects the request.
4. `FHE.allowThis()` is required so the contract can re-read its own stored handles in later transactions.

---

## API Reference

### Supported chains

| Chain | Chain ID |
|-------|----------|
| Ethereum mainnet | `1` |
| Sepolia testnet | `11155111` |
| Local Hardhat | `31337` |

Any other chain ID causes `ZamaEthereumConfig`'s constructor to revert with `ZamaProtocolUnsupported()`.

### Handle type

All encrypted values are `bytes32` handles on-chain. The FHEVM Solidity library wraps `bytes32` in named types (`euint8`, `euint32`, `euint64`, `ebool`, `eaddress`, etc.) for type safety — they are interchangeable at the ABI level. See [`references/encrypted-types.md`](./encrypted-types.md) for the full type table.

### `ZamaEthereumConfig` (coprocessor registration)

```solidity
// @fhevm/solidity@0.11.1
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Inherit — never deploy ZamaEthereumConfig directly (it is abstract).
contract MyContract is ZamaEthereumConfig {
    // ZamaEthereumConfig() constructor call registers the coprocessor and Gateway
    // addresses for the current chain.
}
```

`ERC7984` does **not** inherit `ZamaEthereumConfig` — always add it explicitly alongside `ERC7984`.

---

## Common Patterns

### Always inherit `ZamaEthereumConfig`

```solidity
// @fhevm/solidity@0.11.1
// Every FHEVM contract must inherit ZamaEthereumConfig.
// Without it, FHE operations revert on mainnet and Sepolia.
import { FHE, euint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MyContract is ZamaEthereumConfig {
    euint32 private _value;
}
```

### Grant ACL immediately after every FHE operation that produces a stored handle

```solidity
// @fhevm/solidity@0.11.1
// ACL grants must follow every FHE op whose result you intend to store.
// Missing grants cause silent failures — no revert, no event.
euint64 result = FHE.add(a, b);
FHE.allowThis(result);         // contract can re-read result in future transactions
FHE.allow(result, msg.sender); // user can decrypt via Gateway
_stored = result;
```

### Handles are opaque references — use FHE ops to compare values

```solidity
// @fhevm/solidity@0.11.1
// ❌ Handle equality does NOT imply plaintext equality — two different handles
//    can reference ciphertexts for the same plaintext; they will not be == .
// if (handleA == handleB) { ... }  // meaningless

// ✅ Compare plaintexts using FHE operations — returns an ebool ciphertext
ebool equal = FHE.eq(handleA, handleB);
```

---

## Anti-Patterns

**❌ Fhenix / CoFHE API confusion**
> Fhenix and CoFHE are alternative FHE-on-EVM frameworks with similar concepts but different APIs. Common mistranslations when switching from Fhenix:

| Concept | Zama FHEVM (`@fhevm/solidity`) | Fhenix (`@fhenixprotocol/contracts`) |
|---------|-------------------------------|--------------------------------------|
| Library | `FHE` | `TFHE` |
| Encrypted uint | `euint32` | `euint32` (same) |
| Addition | `FHE.add(a, b)` | `TFHE.add(a, b)` |
| Input proof required | Yes — `externalEuint*` + `inputProof` | No |
| ACL grants | `FHE.allowThis`, `FHE.allow` | Not applicable |

> When working with Zama FHEVM, always import from `@fhevm/solidity` and use `FHE.*`, never `TFHE.*`.

---

**❌ Deploying `ZamaEthereumConfig` directly**
> `ZamaEthereumConfig` is abstract. Attempting to deploy it directly fails at compile time.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Compile error — ZamaEthereumConfig is abstract
> new ZamaEthereumConfig();
> ```

**✅ Correct pattern — inherit it**
> ```solidity
> // @fhevm/solidity@0.11.1
> contract MyContract is ZamaEthereumConfig { ... }
> ```

---

**❌ Using handles as plaintext values**
> A `bytes32` handle is an opaque pointer to a ciphertext on the coprocessor — it reveals nothing about the plaintext. Logging, comparing, or performing arithmetic on the raw handle value is meaningless.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Logs an opaque handle, not the encrypted balance
> emit BalanceUpdate(euint64.unwrap(_balance));
> ```
> There is no way to read the plaintext on-chain without going through the decryption Gateway.

---

## See Also

- [`references/encrypted-types.md`](./encrypted-types.md) — encrypted type reference (`euint*`, `ebool`, `eaddress`)
- [`references/access-control.md`](./access-control.md) — ACL functions (`allowThis`, `allow`, `allowTransient`)
- [`references/input-proofs.md`](./input-proofs.md) — user input ZK proof verification
- [`references/fhe-operations.md`](./fhe-operations.md) — all FHE operations
- [`references/decryption-flows.md`](./decryption-flows.md) — user and public decryption
- [`references/testing-patterns.md`](./testing-patterns.md) — Hardhat mock environment
- [`references/frontend-integration.md`](./frontend-integration.md) — client-side SDK selection
- [`references/erc7984.md`](./erc7984.md) — confidential token standard
- [`references/anti-patterns.md`](./anti-patterns.md) — security anti-patterns catalogue
