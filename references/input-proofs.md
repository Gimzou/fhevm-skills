# Input Proofs

## Overview

When a user supplies an encrypted value to a contract, they must also provide an **input proof** — a zero-knowledge proof that binds the ciphertext to their Ethereum address. This prevents an attacker from replaying another user's valid ciphertext: each proof is cryptographically tied to `msg.sender` at proof generation time.

The mandatory call sequence is:
1. `FHE.fromExternal(encInput, inputProof)` — verifies the ZK proof and returns an internal handle. As a side effect it calls `allowTransient(result, msg.sender)`, granting the caller transient ACL access on the resulting handle.
2. `FHE.isSenderAllowed(v)` on the **internal handle** — defense-in-depth check that the transient grant was applied.

`FHE.isSenderAllowed()` does **not** accept `externalEuint*` parameters. Calling it on the external input causes a Solidity compile error (`Member not found after argument-dependent lookup`). It must be called on the internal handle returned by `fromExternal`.

---

## Complete Example

```solidity
// @fhevm/solidity@0.11.1
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Demonstrates the correct fromExternal → isSenderAllowed → allowThis + allow order.
contract InputProofDemo is ZamaEthereumConfig {
    mapping(address => euint64) private _values;

    function store(externalEuint64 encInput, bytes calldata inputProof) external {
        // Step 1: verify ZK proof + get internal handle
        // fromExternal also grants allowTransient(v, msg.sender) as a side effect
        euint64 v = FHE.fromExternal(encInput, inputProof);

        // Step 2: defense-in-depth — confirm transient grant was applied
        // MUST be on the internal handle v, NOT on encInput (compile error if on externalEuint64)
        require(FHE.isSenderAllowed(v), "Caller lacks ACL access");

        // Step 3: grant persistent ACL access before storing
        FHE.allowThis(v);          // contract can re-read in future transactions
        FHE.allow(v, msg.sender);  // caller can decrypt via gateway

        _values[msg.sender] = v;
    }

    function getValue() external view returns (euint64) {
        return _values[msg.sender];
    }
}
```

---

## API Reference

```solidity
FHE.fromExternal(encInput, inputProof) → euintX
    // externalEuintX + bytes → euintX
    // Verifies ZK proof. Reverts if proof is invalid or does not bind to msg.sender.
    // Side effect: grants allowTransient(result, msg.sender)

FHE.isSenderAllowed(handle) → bool
    // euintX → bool
    // Returns true if msg.sender has ACL access on the internal handle.
    // ❌ Does NOT accept externalEuint* — compile error if called on external param.
```

---

## Common Patterns

### Correct call order with causal annotations

```solidity
// @fhevm/solidity@0.11.1
function receive(externalEuint32 enc, bytes calldata proof) external {
    // 1. fromExternal: ZK proof verification + transient ACL grant
    //    Without this, v is undefined; isSenderAllowed below would have nothing to check.
    euint32 v = FHE.fromExternal(enc, proof);

    // 2. isSenderAllowed: defense-in-depth
    //    fromExternal grants allowTransient(v, msg.sender); this verifies that grant exists.
    //    Not strictly necessary (fromExternal would have reverted on invalid proof),
    //    but catches edge cases where ACL state is inconsistent.
    require(FHE.isSenderAllowed(v), "Sender not authorized");

    // 3. Persistent grants before storage
    FHE.allowThis(v);
    FHE.allow(v, msg.sender);
    _state = v;
}
```

### Multi-value input (multiple encrypted params in one call)

```solidity
// @fhevm/solidity@0.11.1
// One inputProof covers all encrypted params in the same call.
function swap(
    externalEuint64 encAmountIn,
    externalEuint64 encAmountOut,
    bytes calldata inputProof   // single proof binds both handles to msg.sender
) external {
    euint64 amtIn  = FHE.fromExternal(encAmountIn,  inputProof);
    euint64 amtOut = FHE.fromExternal(encAmountOut, inputProof);
    require(FHE.isSenderAllowed(amtIn),  "Sender not authorized for amtIn");
    require(FHE.isSenderAllowed(amtOut), "Sender not authorized for amtOut");
    // ... rest of logic
}
```

---

## Anti-Patterns

**❌ Calling `isSenderAllowed` on `externalEuint*` — compile error**
> `FHE.isSenderAllowed()` accepts only internal handles. Passing the raw external parameter causes: `Member "isSenderAllowed" not found or not visible after argument-dependent lookup`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Compile error
> function store(externalEuint32 enc, bytes calldata proof) external {
>     require(FHE.isSenderAllowed(enc), "unauthorized"); // enc is externalEuint32 — wrong type
> }
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ fromExternal first, then isSenderAllowed on the internal handle
> function store(externalEuint32 enc, bytes calldata proof) external {
>     euint32 v = FHE.fromExternal(enc, proof);  // internal handle
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     // ...
> }
> ```

---

**❌ Accepting encrypted values from arbitrary callers without address binding (replay attack)**
> A contract that accepts ciphertexts from any caller without verifying proof-to-sender binding allows an attacker to replay a victim's valid `(encInput, inputProof)` pair. Because the proof was generated for the victim's address, replaying it from the attacker's address will cause `fromExternal` to revert — but contracts that skip `fromExternal` and accept raw handles are vulnerable.
>
> Always use `FHE.fromExternal()` as the sole entry point for user-supplied ciphertexts. Never accept a pre-converted internal handle from an untrusted caller.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Dangerous — accepts an internal handle from an untrusted caller
> function store(euint32 v) external {
>     // No proof verification — attacker can pass any handle they can observe
>     FHE.allowThis(v);
>     _value = v;
> }
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Always start from externalEuint* + inputProof
> function store(externalEuint32 enc, bytes calldata proof) external {
>     euint32 v = FHE.fromExternal(enc, proof); // proof must bind to msg.sender
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _value = v;
> }
> ```

---

## See Also

- [`references/access-control.md`](./access-control.md) — ACL grants after `fromExternal`
- [`references/encrypted-types.md`](./encrypted-types.md) — `externalEuint*` type reference
- [`references/testing-patterns.md`](./testing-patterns.md) — generating `inputProof` in tests
