# Access Control

## Overview

Every encrypted handle in FHEVM has an Access Control List (ACL). An address can use a ciphertext in an FHE operation only if it holds ACL permission for that handle. Without an ACL grant, operations silently fail — no revert, no event; the ciphertext is simply unusable.

Two permission lifetimes exist:

- **Persistent** (`allow`, `allowThis`) — survives across transactions. Required when storing state that must be re-readable in a later call.
- **Transient** (`allowTransient`) — cleared at the end of the current transaction. Preferred for helper contracts or intermediate results that are not stored.

Key contracts (the FHE coprocessor) also need ACL grants to execute operations. `FHE.fromExternal()` implicitly grants transient access; `allowThis` grants the storing contract persistent access so it can re-read its own state.

---

## Complete Example

```solidity
// @fhevm/solidity@0.11.1
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Demonstrates allowThis + allow + allowTransient in a realistic vault pattern.
// Uses per-user mapping to avoid the ACL overwrite footgun (see Anti-Patterns).
contract VaultDemo is ZamaEthereumConfig {
    // Per-user mapping — each user's handle is isolated.
    // Avoids the footgun where a single-slot state leaves old handles permanently ACL'd.
    mapping(address => euint64) private _balances;

    address public immutable helper; // trusted helper contract

    constructor(address _helper) {
        helper = _helper;
    }

    // Deposit: store an encrypted balance for the caller.
    function deposit(externalEuint64 encAmt, bytes calldata inputProof) external {
        euint64 v = FHE.fromExternal(encAmt, inputProof);
        require(FHE.isSenderAllowed(v), "Sender not authorized");
        FHE.allowThis(v);           // contract can read its own state in future txs
        FHE.allow(v, msg.sender);   // caller can decrypt their balance persistently
        // allowTransient for helper — access lives only for this transaction
        FHE.allowTransient(v, helper);
        _balances[msg.sender] = v;
    }

    // Return the caller's encrypted balance handle.
    // isInitialized guard prevents returning bytes32(0) before any deposit,
    // which would cause "Handle is not initialized" on the TypeScript side.
    function balanceOf() external view returns (euint64) {
        require(FHE.isInitialized(_balances[msg.sender]), "Balance not initialized");
        return _balances[msg.sender];
    }
}
```

---

## API Reference

```solidity
FHE.allowThis(handle)                       // grants contract itself persistent access
FHE.allow(handle, address)                  // grants address persistent access
FHE.allowTransient(handle, address)         // grants address transient access (this tx only)
FHE.makePubliclyDecryptable(handle)         // marks handle for public KMS decryption
FHE.isSenderAllowed(handle) → bool          // checks if msg.sender has ACL access (internal handle only)
FHE.isAllowed(handle, address) → bool       // checks if address has ACL access
FHE.cleanTransientStorage()                 // clears transient ACL state (required in AA wallet contexts)
```

### Delegation API (user decryption delegation)

Delegation is scoped per **(delegator = `address(this)`, delegate, contractAddress)** tuple, **not per handle**. The delegate may request user decryption for any ciphertext whose context includes `contractAddress`, on behalf of the calling contract.

```solidity
FHE.delegateUserDecryption(delegate, contractAddress, expirationDate)             // uint64 UNIX timestamp
FHE.delegateUserDecryptionWithoutExpiration(delegate, contractAddress)            // permanent until revoked
FHE.delegateUserDecryptions(delegate, contractAddresses[], expirationDate)        // batch, uint64 expiry
FHE.delegateUserDecryptionsWithoutExpiration(delegate, contractAddresses[])       // batch, permanent
FHE.revokeUserDecryptionDelegation(delegate, contractAddress)                     // single revoke
FHE.revokeUserDecryptionDelegations(delegate, contractAddresses[])                // batch revoke
FHE.getDelegatedUserDecryptionExpirationDate(
    delegator, delegate, contractAddress
) → uint64                                                                        // 0 = none, max = permanent
FHE.isDelegatedForUserDecryption(delegator, delegate, contractAddress, handle) → bool
    // NOTE: 4-arg signature — the handle is required because the check also verifies
    //       that (delegator, contractAddress) currently has ACL access to `handle`.
```

**Preconditions enforced by `delegateUserDecryption`:**
- `expirationDate >= block.timestamp + 1 hours` — shorter expiries revert with `ACL.ExpirationDateBeforeOneHour`.
- `contractAddress != address(this)` — reverts with `ACL.SenderCannotBeContractAddress`.
- `delegate != address(this)` — reverts with `ACL.SenderCannotBeDelegate`.
- `delegate != contractAddress` — reverts with `ACL.DelegateCannotBeContractAddress`.
- At most one delegate OR revoke per block for the same `(address(this), delegate, contractAddress)` tuple — otherwise reverts with `ACL.AlreadyDelegatedOrRevokedInSameBlock`.

---

## Common Patterns

### Dual grant — store + allow caller to decrypt

```solidity
// @fhevm/solidity@0.11.1
// Both calls required. Omitting allowThis silently breaks user decryption.
FHE.allowThis(v);          // so this contract can re-read v in future transactions
FHE.allow(v, msg.sender);  // so the caller can decrypt v via the gateway
_stored = v;
```

### Transient grant for helper contracts

```solidity
// @fhevm/solidity@0.11.1
// Prefer allowTransient over allow when the helper only needs access within this call.
// Persistent allow would leave the helper with indefinite ciphertext access.
FHE.allowTransient(v, helperContract);
IHelper(helperContract).process(v);
// After this tx, helperContract's ACL grant is gone automatically.
```

### Per-user mapping (production pattern)

```solidity
// @fhevm/solidity@0.11.1
// Use a mapping so each user's handle is isolated.
// Avoids the ACL overwrite footgun (see Anti-Patterns).
mapping(address => euint64) private _balances;

function store(externalEuint64 encAmt, bytes calldata proof) external {
    euint64 v = FHE.fromExternal(encAmt, proof);
    require(FHE.isSenderAllowed(v), "Sender not authorized");
    FHE.allowThis(v);
    FHE.allow(v, msg.sender);
    _balances[msg.sender] = v;
}
```

---

## Anti-Patterns

**❌ Missing `allowThis()` — silently breaks user decryption**
> Granting only `FHE.allow(v, msg.sender)` without `FHE.allowThis(v)` means the contract loses the ability to reference its own state in subsequent transactions. When the user later calls a getter and tries to decrypt via the gateway, decryption silently fails — no revert, no error message.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Missing allowThis — user decryption will fail silently
> FHE.allow(v, msg.sender);
> _value = v;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Both grants required
> FHE.allowThis(v);          // contract can re-read its own state
> FHE.allow(v, msg.sender);  // caller can decrypt
> _value = v;
> ```

---

**❌ Over-broad persistent `allow()` on helper contracts**
> Using `FHE.allow(v, helperContract)` gives the helper indefinite access to the ciphertext across all future transactions. If the helper is upgradeable or compromised, all ciphertexts it was ever granted become readable.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Helper gets permanent ciphertext access
> FHE.allow(v, helperContract);
> IHelper(helperContract).process(v);
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Access is scoped to the current transaction only
> FHE.allowTransient(v, helperContract);
> IHelper(helperContract).process(v);
> ```

---

**❌ ACL overwrite footgun — single-slot state leaks old handles**
> When a single storage slot holds the ciphertext (`euint64 private _value`), writing a new ciphertext overwrites the slot — but the old handle's ACL grants are permanent. `FHE.disallow()` does not exist. Every address that was ever granted access to an old handle retains that access indefinitely, turning superseded ciphertexts into browsable history.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Old handles remain ACL-accessible after overwrite
> euint64 private _value; // single slot for all users
>
> function update(externalEuint64 enc, bytes calldata proof) external {
>     euint64 v = FHE.fromExternal(enc, proof);
>     require(FHE.isSenderAllowed(v), "Sender not authorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _value = v; // previous handle's ACL grants are NOT revoked
> }
> ```

**✅ Correct pattern — per-user mapping**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Each user's handle is isolated — other users cannot see each other's handles
> mapping(address => euint64) private _values;
>
> function update(externalEuint64 enc, bytes calldata proof) external {
>     euint64 v = FHE.fromExternal(enc, proof);
>     require(FHE.isSenderAllowed(v), "Sender not authorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _values[msg.sender] = v;
>     // Old handle for msg.sender becomes browsable history (only for msg.sender — isolated)
> }
> ```
> A mapping does not eliminate the history of old handles for the same user, but it prevents cross-user leakage. For sensitive updates where old values must not be readable, use a commit-reveal pattern or re-encryption.

---

## See Also

- [`references/input-proofs.md`](./input-proofs.md) — `fromExternal` + `isSenderAllowed` call order
- [`references/decryption-flows.md`](./decryption-flows.md) — user and public decryption flows
- [`references/encrypted-types.md`](./encrypted-types.md) — available encrypted types
