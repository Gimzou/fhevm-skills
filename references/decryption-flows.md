# Decryption Flows

## Overview

FHEVM supports two decryption modes. Choose based on who the result is for:

| Flow | Result visible to | When to use |
|------|-------------------|-------------|
| **User decryption** | Specific address only | Revealing a user's private balance, vote, or bid |
| **Public decryption** | Anyone | Publishing an election result, auction winner, or aggregated stat |

Both flows require ACL setup on the contract side before decryption can happen.

**⚠️ Known limitation (Medium confidence):** Returning an encrypted handle from a `view` function works at the Solidity level, but the caller receives a handle they cannot use in further FHE operations. The handle is only useful as input to `userDecryptEuint` / `publicDecryptEuint` — composability with other FHE contracts is broken. This limitation is under investigation for v0.12.0.

---

## Complete Example

Decryption inherently spans two standalone files: a Solidity contract that grants ACL / emits the publish call, and a TypeScript test that invokes the gateway-side helper. Each block below is a self-contained file — save as shown and it compiles / runs as-is.

**File 1 — `UserDecryptExample.sol` (contract)**

```solidity
// @fhevm/solidity@0.11.1
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract UserDecryptExample is ZamaEthereumConfig {
    event PublishedSecret(address indexed owner, bytes32 handle);

    mapping(address => euint32) private _secrets;

    function setSecret(externalEuint32 encInput, bytes calldata inputProof) external {
        euint32 v = FHE.fromExternal(encInput, inputProof);
        require(FHE.isSenderAllowed(v), "Sender not authorized");
        // Both grants required: allowThis so contract can read it, allow so user can decrypt
        FHE.allowThis(v);
        FHE.allow(v, msg.sender);
        _secrets[msg.sender] = v;
    }

    // Caller uses the returned handle with the gateway to decrypt their secret.
    function getSecretHandle() external view returns (euint32) {
        require(FHE.isInitialized(_secrets[msg.sender]), "Secret not set");
        return _secrets[msg.sender];
    }

    // Mark the caller's secret for public decryption and emit an event the Relayer can observe.
    // Handle order in makePubliclyDecryptable must match checkSignatures when verifying.
    function publishSecret() external {
        require(FHE.isInitialized(_secrets[msg.sender]), "Secret not set");
        euint32 v = _secrets[msg.sender];
        FHE.makePubliclyDecryptable(v);
        emit PublishedSecret(msg.sender, euint32.unwrap(v));
    }
}
```

**File 2 — `userDecryptExample.ts` (Hardhat test covering both flows)**

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
import { ethers, fhevm } from "hardhat";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

describe("UserDecryptExample", function () {
  before(function () {
    if (!fhevm.isMock) throw new Error("This test suite cannot run on Sepolia");
  });

  it("reveals a secret to its owner and, after publish, to anyone", async function () {
    const [owner] = await ethers.getSigners();
    const contract = await (await ethers.getContractFactory("UserDecryptExample")).deploy();
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    const input = fhevm.createEncryptedInput(contractAddress, owner.address);
    input.add32(1234n);
    const { handles, inputProof } = await input.encrypt();
    await contract.setSecret(handles[0], inputProof);

    // User decryption — 4th arg is the Signer object, NOT owner.address (string)
    const userHandle = await contract.getSecretHandle();
    const secret = await fhevm.userDecryptEuint(FhevmType.euint32, userHandle, contractAddress, owner);
    expect(secret).to.equal(1234n);

    // Public decryption — Relayer picks up the handle from the emitted event
    await contract.publishSecret();
    const publicValue = await fhevm.publicDecryptEuint(FhevmType.euint32, userHandle);
    expect(publicValue).to.equal(1234n);
  });
});
```

---

## API Reference

### Contract-side ACL (prerequisite for both flows)

```solidity
FHE.allowThis(handle)              // required — contract must be able to read its own state
FHE.allow(handle, address)         // grants address user-decryption access (persistent)
FHE.makePubliclyDecryptable(handle) // registers handle for public KMS decryption
```

### Test-side helpers (Hardhat mock environment)

**User decryption**

```typescript
// Single euint — returns bigint
fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, signer)   // → bigint
fhevm.userDecryptEbool(handle, contractAddress, signer)                       // → boolean
fhevm.userDecryptEaddress(handle, contractAddress, signer)                    // → string
```

**Keypair helpers (for manual EIP-712 flows)**

```typescript
fhevm.generateKeypair()                                         // → { publicKey, privateKey }
fhevm.createEIP712(publicKey, [contractAddress], startTs, days) // → EIP-712 typed data to sign
```

**Public decryption (after `makePubliclyDecryptable` on-chain)**

```typescript
fhevm.publicDecryptEuint(FhevmType.euint32, handle)  // → bigint
fhevm.publicDecryptEbool(handle)                      // → boolean
fhevm.publicDecryptEaddress(handle)                   // → string
fhevm.publicDecrypt([handle1, handle2])               // bulk — returns array
```

### On-chain public decryption verification

```solidity
// Called in the KMS callback to verify the decryption result.
// Reverts (no bool return) with InvalidKMSSignatures if verification fails.
// handlesList order must EXACTLY match the order used in makePubliclyDecryptable() calls —
// the proof is bound to that ordering.
FHE.checkSignatures(
    bytes32[] memory handlesList,
    bytes memory abiEncodedCleartexts,
    bytes memory decryptionProof
) internal   // returns void; reverts on failure
```

---

## Common Patterns

### EIP-712 user decryption flow (full manual steps)

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
// Step 1: generate an FHE keypair
const { publicKey, privateKey } = fhevm.generateKeypair();

// Step 2: build EIP-712 typed data for the keypair
const startTimestamp = Math.floor(Date.now() / 1000);
const durationDays   = 1;
const eip712 = fhevm.createEIP712(publicKey, [contractAddress], startTimestamp, durationDays);

// Step 3: sign with the user's wallet
const signature = await signer.signTypedData(eip712.domain, eip712.types, eip712.message);

// Step 4: multi-value decryption using the signed keypair
const results = await fhevm.userDecrypt(
  [{ handle: handle1, contractAddress }, { handle: handle2, contractAddress }],
  privateKey,
  publicKey,
  signature,
  [contractAddress],
  await signer.getAddress(),
  startTimestamp,
  durationDays
);
// results is a Record keyed by handle hex string (0x...), NOT an array.
// Index by the original handle, not by numeric position:
const firstValue  = results[handle1 as `0x${string}`];   // bigint | boolean | string
const secondValue = results[handle2 as `0x${string}`];
```

### Public decryption callback with `checkSignatures`

```solidity
// @fhevm/solidity@0.11.1
// Called by the KMS gateway after public decryption is complete.
// handlesList order must match the makePubliclyDecryptable() call order.
// checkSignatures returns void and reverts on failure — do not wrap in require().
function publicDecryptCallback(
    bytes32[] memory handlesList,
    bytes memory abiEncodedCleartexts,
    bytes memory decryptionProof
) external {
    FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof); // reverts if invalid
    // ... parse abiEncodedCleartexts and process result
}
```

---

## Anti-Patterns

**❌ Missing `allowThis()` before user decryption**
> Without `FHE.allowThis(v)`, the contract cannot reference its own stored ciphertext in subsequent transactions. When the user later calls `userDecryptEuint`, the gateway finds the contract has no ACL access and decryption silently fails — no revert, just a useless handle.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Missing allowThis — user decryption fails silently
> FHE.allow(v, msg.sender);
> _secret = v;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> FHE.allowThis(v);          // required
> FHE.allow(v, msg.sender);
> _secret = v;
> ```

---

**❌ Handle order mismatch in `checkSignatures`**
> `FHE.checkSignatures(handlesList, abiEncodedCleartexts, proof)` is cryptographically binding: the proof is over a specific ordering of handles. If the contract calls `makePubliclyDecryptable(a)` then `makePubliclyDecryptable(b)`, the callback must pass handles in `[a, b]` order. Reversing them causes `checkSignatures` to revert with `InvalidKMSSignatures`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Mismatch: makePubliclyDecryptable order is [a, b] but checkSignatures sees [b, a]
> FHE.makePubliclyDecryptable(a);
> FHE.makePubliclyDecryptable(b);
> // ... in callback:
> bytes32[] memory wrong = new bytes32[](2);
> wrong[0] = euint32.unwrap(b); wrong[1] = euint32.unwrap(a);
> FHE.checkSignatures(wrong, cleartexts, proof); // reverts — wrong order
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Callback handle order matches makePubliclyDecryptable call order
> FHE.makePubliclyDecryptable(a);
> FHE.makePubliclyDecryptable(b);
> // ... in callback:
> bytes32[] memory ordered = new bytes32[](2);
> ordered[0] = euint32.unwrap(a); ordered[1] = euint32.unwrap(b);
> FHE.checkSignatures(ordered, cleartexts, proof); // verified — handle order matches publish order
> ```

---

**❌ Replayable public decryption callback — external call before cleanup**
> `FHE.checkSignatures` only verifies that the KMS signed these cleartexts; it does not track whether the callback has already been consumed. If the callback sends ETH (or makes any external call) **before** deleting the pending-decryption record, a reentrant attacker can re-enter the same callback, pass `checkSignatures` a second time (the KMS signature is still valid), and trigger the payout again. The bug is not in `checkSignatures` — it is in ordering the cleanup after the external call.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ External call before cleanup — callback is replayable on reentry
> function callback(
>     bytes32[] memory handlesList,
>     bytes memory abiEncodedCleartexts,
>     bytes memory decryptionProof
> ) external {
>     FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);
>     payable(winner).transfer(prize); // external call first
>     delete pendingDecryption;        // cleanup after — too late
> }
> ```

**✅ Correct pattern — cleanup before external calls (checks-effects-interactions)**
> ```solidity
> // @fhevm/solidity@0.11.1
> function callback(
>     bytes32[] memory handlesList,
>     bytes memory abiEncodedCleartexts,
>     bytes memory decryptionProof
> ) external {
>     FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);
>     delete pendingDecryption; // mark consumed BEFORE external call
>     payable(winner).transfer(prize);
> }
> ```

---

**⚠️ View function limitation — handle unusable in further FHE operations (Medium confidence)**
> A getter that returns an encrypted handle (`euint32`) compiles and runs without error. However, the caller receives a handle they cannot pass to further FHE contract operations — it is only useful for `userDecryptEuint` / `publicDecryptEuint`. Composability between FHE contracts via view function returns is broken at the protocol level. Do not design contracts that rely on a callee passing returned handles into FHE operations in a second contract.

---

## See Also

- [`references/access-control.md`](./access-control.md) — ACL grants required for both decryption flows
- [`references/testing-patterns.md`](./testing-patterns.md) — full test examples for both flows
- [`_validation/contracts/DecryptionFlows.sol`](../_validation/contracts/DecryptionFlows.sol) — validated contract showing both flows
- [`_validation/test/decryptionFlows.ts`](../_validation/test/decryptionFlows.ts) — passing tests for both flows
