# Anti-Patterns

## Overview

Consolidated anti-pattern catalogue for FHEVM development. Every entry originates from a validated reference file (Stories 1.1–1.4) or from `specs/project-context.md` (marked *project-context*). Use for pre-PR security sweeps; follow the `See Also` links for deeper context.

All Solidity examples target `@fhevm/solidity@0.11.1`.

---

## Complete Example

A contract intentionally demonstrating three common anti-patterns, followed by the corrected version.

### ❌ Bad contract — 3 anti-patterns

```solidity
// @fhevm/solidity@0.11.1
// ❌ BAD: oversized type, missing allowThis, no overflow guard
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint256, externalEuint256 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract BadCounter is ZamaEthereumConfig {
    euint256 private _counter; // ❌ euint256 for a simple counter — 8× gas cost vs euint32

    function set(externalEuint256 encInput, bytes calldata inputProof) external {
        euint256 v = FHE.fromExternal(encInput, inputProof);
        // ❌ Missing allowThis — user decryption fails silently; no revert, no error
        FHE.allow(v, msg.sender);
        _counter = v;
    }

    function increment() external {
        // ❌ No overflow guard — euint256 wraps silently on overflow
        _counter = FHE.add(_counter, 1);
    }

    function getCounter() external view returns (euint256) {
        // ❌ No isInitialized guard — returns bytes32(0) before any set()
        return _counter;
    }
}
```

### ✅ Corrected contract

```solidity
// @fhevm/solidity@0.11.1
// ✅ CORRECTED: right-sized type, dual ACL grant, overflow guard, isInitialized guard
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract GoodCounter is ZamaEthereumConfig {
    mapping(address => euint32) private _counters; // per-user mapping avoids ACL overwrite footgun

    function set(externalEuint32 encInput, bytes calldata inputProof) external {
        euint32 v = FHE.fromExternal(encInput, inputProof);
        require(FHE.isSenderAllowed(v), "Sender not authorized");
        FHE.allowThis(v);          // ✅ contract can re-read in future transactions
        FHE.allow(v, msg.sender);  // ✅ caller can decrypt via gateway
        _counters[msg.sender] = v;
    }

    function increment() external {
        euint32 current = _counters[msg.sender];
        require(FHE.isInitialized(current), "Counter not initialized");
        euint32 newVal     = FHE.add(current, 1);
        ebool   overflowed = FHE.lt(newVal, current); // ✅ overflow guard
        euint32 result     = FHE.select(overflowed, current, newVal);
        FHE.allowThis(result);
        FHE.allow(result, msg.sender);
        _counters[msg.sender] = result;
    }

    function getCounter() external view returns (euint32) {
        require(FHE.isInitialized(_counters[msg.sender]), "Counter not initialized"); // ✅
        return _counters[msg.sender];
    }
}
```

---

## API Reference

Quick-reference index. **High** = silent failure or security risk; **Med** = runtime error with signal; **Low** = gas waste.

| Anti-pattern | Severity | Domain | Reference |
|---|---|---|---|
| Missing `allowThis()` — user decrypt fails silently | High | ACL | `references/access-control.md` |
| Over-broad `allow()` on helper contracts | Med | ACL | `references/access-control.md` |
| ACL overwrite footgun — single-slot ciphertext | Med | ACL | `references/access-control.md` |
| Transient ACL leak in AA wallets | Med | ACL | *project-context* |
| Arbitrary external calls from ciphertext-holding contracts | High | ACL | *project-context* |
| `isSenderAllowed` on `externalEuint*` — compile error | High | Input | `references/input-proofs.md` |
| Third-party encrypted input replay | High | Input | `references/input-proofs.md` |
| FHE arithmetic overflow without select-guard | High | Arithmetic | `references/fhe-operations.md` |
| `randEuintNN(upperBound)` with non-power-of-two bound | High | Arithmetic | `references/fhe-operations.md` |
| Loop condition on `ebool` | High | Arithmetic | `references/fhe-operations.md` |
| Unnecessary `asEuintXX(scalar)` wrapping | Low | Arithmetic | `references/fhe-operations.md` |
| Oversized encrypted type | Low | Types | `references/encrypted-types.md` |
| `euint4` in Solidity | High | Types | `references/encrypted-types.md` |
| Handle order mismatch in `checkSignatures` | High | Decryption | `references/decryption-flows.md` |
| Replayable callback — cleanup after external call | High | Decryption | `references/decryption-flows.md` |
| Information disclosure via block reorgs | Med | Decryption | *project-context* |
| `hardhat-toolbox@5` HH801 error | High | Testing | `references/testing-patterns.md` |
| `userDecryptEuint` 4th arg is string, not Signer | High | Testing | `references/testing-patterns.md` |
| Zero handle — "Handle is not initialized" | Med | Testing | `references/testing-patterns.md` |
| Missing mock guard | Med | Testing | `references/testing-patterns.md` |
| `@fhevm/sdk` does not exist on npm | High | SDK | `references/frontend-integration.md` |
| `@zama-fhe/sdk` for non-token contracts | Med | SDK | `references/frontend-integration.md` |
| `fhevmjs` in new code | Low | SDK | `references/frontend-integration.md` |
| Missing `ZamaEthereumConfig` when inheriting `ERC7984` | High | ERC-7984 | `references/erc7984.md` |
| Ignoring `confidentialTransfer` return value | High | ERC-7984 | `references/erc7984.md` |

---

## Common Patterns

The four patterns that prevent the most common mistakes:

### 1. Dual ACL grant (allowThis + allow)

```solidity
// @fhevm/solidity@0.11.1
// Always both. Omitting allowThis silently breaks user decryption — no error thrown.
FHE.allowThis(v);          // contract can re-read its own state in future txs
FHE.allow(v, msg.sender);  // caller can decrypt via gateway
_stored = v;
```

### 2. Overflow guard with `FHE.select`

```solidity
// @fhevm/solidity@0.11.1
// FHE arithmetic wraps silently. Always guard with select + lt.
euint64 newSupply  = FHE.add(totalSupply, mintedAmount);
ebool   overflowed = FHE.lt(newSupply, totalSupply);
totalSupply        = FHE.select(overflowed, totalSupply, newSupply);
```

### 3. `isSenderAllowed` call order (internal handle only)

```solidity
// @fhevm/solidity@0.11.1
// fromExternal FIRST, then isSenderAllowed on the returned internal handle.
// Calling isSenderAllowed on externalEuint* causes a compile error.
euint64 v = FHE.fromExternal(encInput, inputProof); // internal handle
require(FHE.isSenderAllowed(v), "unauthorized");     // on v, NOT on encInput
```

### 4. `allowTransient` for helper contracts

```solidity
// @fhevm/solidity@0.11.1
// Prefer transient over persistent — access is scoped to this transaction only.
FHE.allowTransient(v, helperContract);
IHelper(helperContract).process(v);
// helperContract's ACL grant is automatically cleared after the tx.
```

---

## Anti-Patterns

### ACL

**❌ Missing `allowThis()` — silently breaks user decryption**
> Without `FHE.allowThis(v)`, the contract loses ACL access to its own stored ciphertext. When the user later calls `userDecryptEuint`, the gateway finds no contract ACL entry and decryption silently fails — no revert, no error event.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Only one grant — contract loses access to its own state
> FHE.allow(v, msg.sender);
> _value = v;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> FHE.allowThis(v);          // required — omitting silently breaks user decryption
> FHE.allow(v, msg.sender);
> _value = v;
> ```
> _Sources: `references/access-control.md`, `references/decryption-flows.md`_

---

**❌ Over-broad persistent `allow()` on helper contracts**
> `FHE.allow(v, helperContract)` gives the helper indefinite access across all future transactions. If the helper is upgradeable or compromised, every ciphertext it was ever granted remains accessible.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Helper has permanent ciphertext access
> FHE.allow(v, helperContract);
> IHelper(helperContract).process(v);
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> FHE.allowTransient(v, helperContract); // access cleared after this tx
> IHelper(helperContract).process(v);
> ```
> _Source: `references/access-control.md`_

---

**❌ ACL overwrite footgun — single-slot ciphertext**
> Writing a new ciphertext to a single storage slot overwrites the slot, but old handle ACL grants are permanent (`FHE.disallow()` does not exist). Every address ever granted access to an old handle retains it indefinitely.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Old handles remain permanently ACL'd after overwrite
> euint64 private _value; // shared slot
>
> function update(externalEuint64 enc, bytes calldata proof) external {
>     euint64 v = FHE.fromExternal(enc, proof);
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _value = v; // previous handle's ACL grants are NOT revoked
> }
> ```

**✅ Correct pattern — per-user mapping**
> ```solidity
> // @fhevm/solidity@0.11.1
> mapping(address => euint64) private _values; // each user's handle is isolated
>
> function update(externalEuint64 enc, bytes calldata proof) external {
>     euint64 v = FHE.fromExternal(enc, proof);
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _values[msg.sender] = v;
> }
> ```
> _Source: `references/access-control.md`_

---

**❌ Transient ACL leak in AA wallets** _(project-context)_
> In Account Abstraction contexts, multiple FHE operations may execute within a single transaction bundle. Transient ACL state from one operation can leak into a subsequent operation, granting unintended access.

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> executeOp1(enc1, proof1);
> FHE.cleanTransientStorage(); // clear transient ACL between ops
> executeOp2(enc2, proof2);
> ```
> _Source: `specs/project-context.md`_

---

**❌ Arbitrary external calls from contracts holding ciphertexts** _(project-context)_
> A contract that stores ciphertexts and makes arbitrary external calls is vulnerable: a malicious callee can manipulate ACLs during the call, gaining access to stored ciphertexts. Whitelist all external call targets or prohibit them entirely in contracts holding sensitive ciphertexts.
> _Source: `specs/project-context.md`_

---

### Input / Replay

**❌ Calling `isSenderAllowed` on `externalEuint*` — compile error**
> `FHE.isSenderAllowed()` accepts only internal handles. Passing an `externalEuint*` parameter causes: `Member "isSenderAllowed" not found or not visible after argument-dependent lookup`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Compile error — enc is externalEuint32, not euint32
> function store(externalEuint32 enc, bytes calldata proof) external {
>     require(FHE.isSenderAllowed(enc), "unauthorized");
> }
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> function store(externalEuint32 enc, bytes calldata proof) external {
>     euint32 v = FHE.fromExternal(enc, proof); // internal handle
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     // ...
> }
> ```
> _Source: `references/input-proofs.md`_

---

**❌ Third-party encrypted input replay**
> A contract accepting a pre-converted internal handle (`euint*`) from an untrusted caller has no proof verification — an attacker can replay any handle they observed on-chain. Always use `externalEuint*` + `inputProof` as the sole entry point for user-supplied ciphertexts.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ No proof verification — any handle can be passed
> function store(euint32 v) external {
>     FHE.allowThis(v);
>     _value = v;
> }
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> function store(externalEuint32 enc, bytes calldata proof) external {
>     euint32 v = FHE.fromExternal(enc, proof); // proof binds ciphertext to msg.sender
>     require(FHE.isSenderAllowed(v), "unauthorized");
>     FHE.allowThis(v);
>     FHE.allow(v, msg.sender);
>     _value = v;
> }
> ```
> _Source: `references/input-proofs.md`_

---

### Arithmetic

**❌ FHE arithmetic overflow without select-guard**
> FHE arithmetic wraps on overflow with no exception or revert. An unguarded `FHE.add` on a near-maximum value silently produces an incorrect result.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Silently wraps on overflow
> totalSupply = FHE.add(totalSupply, mintedAmount);
> ```

**✅ Correct pattern — select-guard**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint64 newSupply  = FHE.add(totalSupply, mintedAmount);
> ebool   overflowed = FHE.lt(newSupply, totalSupply);
> totalSupply        = FHE.select(overflowed, totalSupply, newSupply); // saturate on overflow
> ```
> _Source: `references/fhe-operations.md`_

---

**❌ `FHE.randEuintNN(upperBound)` with non-power-of-two bound**
> The bounded-random overloads require `upperBound` to be a power of two. Any other value causes every call to revert with `FHEVMExecutor.NotPowerOfTwo()`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Reverts — 100 is not a power of two
> euint32 roll = FHE.randEuint32(100);
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ 128 is a power of two
> euint32 roll = FHE.randEuint32(128);
> ```
> _Source: `references/fhe-operations.md`_

---

**❌ Loop conditions on encrypted booleans**
> `ebool` is a ciphertext handle, not an EVM boolean. The EVM cannot branch on ciphertext — loop conditions using `ebool` either fail to compile or produce incorrect behavior.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Does not compile — ebool is not a Solidity bool
> while (FHE.lt(x, encryptedMax)) { ... }
> ```

**✅ Correct pattern — use `FHE.select`**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint32 incremented = FHE.add(x, 1);
> ebool   atMax       = FHE.ge(x, encryptedMax);
> x = FHE.select(atMax, x, incremented); // stay at x if at max, else increment
> ```
> _Source: `references/fhe-operations.md`_

---

**❌ Unnecessary `FHE.asEuintXX(scalar)` wrapping**
> All FHE arithmetic functions accept plaintext scalar overloads. Wrapping a scalar in an encrypted type first adds unnecessary gas cost.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Unnecessary conversion
> euint32 result = FHE.add(x, FHE.asEuint32(1));
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint32 result = FHE.add(x, 1); // scalar overload — cheaper
> ```
> _Sources: `references/fhe-operations.md`, `references/encrypted-types.md`_

---

### Types

**❌ Oversized encrypted types**
> Gas cost scales with bit width. `euint256` costs significantly more than `euint8`. Always use the smallest type that correctly represents the value's range.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ euint256 for a percentage (0–100) — 32× the gas of euint8
> euint256 private _percentage;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint8 private _percentage; // fits 0–255; cheapest option
> ```
> _Source: `references/encrypted-types.md`_

---

**❌ Using `euint4` in Solidity**
> `euint4` exists only as a `FhevmType` TypeScript enum value — there is no corresponding Solidity type. Declaring `euint4` in a contract causes a compile error.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Compile error: euint4 is not a valid Solidity type
> euint4 private _nibble;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint8 private _nibble; // smallest available unsigned Solidity type
> ```
> In TypeScript tests, `FhevmType.euint4` is valid for `add4()` on `RelayerEncryptedInput`.
> _Source: `references/encrypted-types.md`_

---

### Decryption

**❌ Handle order mismatch in `FHE.checkSignatures()`**
> `FHE.checkSignatures` is cryptographically bound to a specific handle ordering. The callback handle array must exactly match the order of `makePubliclyDecryptable()` calls — any mismatch reverts with `InvalidKMSSignatures`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Publish order [a, b] but callback passes [b, a]
> FHE.makePubliclyDecryptable(a);
> FHE.makePubliclyDecryptable(b);
> // ... in callback:
> bytes32[] memory wrong = new bytes32[](2);
> wrong[0] = euint32.unwrap(b); wrong[1] = euint32.unwrap(a); // reversed
> FHE.checkSignatures(wrong, cleartexts, proof); // ❌ reverts
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> bytes32[] memory ordered = new bytes32[](2);
> ordered[0] = euint32.unwrap(a); ordered[1] = euint32.unwrap(b); // matches publish order
> FHE.checkSignatures(ordered, cleartexts, proof);
> ```
> _Source: `references/decryption-flows.md`_

---

**❌ Replayable callback — external call before cleanup**
> `FHE.checkSignatures` only verifies the KMS signature — it does not track whether the callback was already consumed. Making an external call before deleting the pending record allows reentrant replay.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ External call first — replayable on reentry
> function callback(bytes32[] memory handlesList, bytes memory cleartexts, bytes memory proof) external {
>     FHE.checkSignatures(handlesList, cleartexts, proof);
>     payable(winner).transfer(prize); // ❌ external call before cleanup
>     delete pendingDecryption;        // too late
> }
> ```

**✅ Correct pattern — checks-effects-interactions**
> ```solidity
> // @fhevm/solidity@0.11.1
> function callback(bytes32[] memory handlesList, bytes memory cleartexts, bytes memory proof) external {
>     FHE.checkSignatures(handlesList, cleartexts, proof);
>     delete pendingDecryption;        // ✅ mark consumed BEFORE external call
>     payable(winner).transfer(prize);
> }
> ```
> _Source: `references/decryption-flows.md`_

---

**❌ Information disclosure via block reorgs** _(project-context)_
> Encrypted values that become publicly decryptable can be observed before finality if a reorg reverses the decryption request. For sensitive disclosures, commit to the disclosure intent in one transaction, then finalize only after sufficient block confirmations.
> _Source: `specs/project-context.md`_

---

### Testing

**❌ `hardhat-toolbox@5` causes HH801 runtime error**
> `@nomicfoundation/hardhat-toolbox@5` lists all sub-packages as `peerDependencies`. With `--legacy-peer-deps`, peer deps are advisory and skipped — toolbox is installed but its dependencies are not, causing `HH801 Plugin ... not installed` at runtime. Do not install or import `hardhat-toolbox`.
> ```bash
> # ❌ toolbox installed but dependencies missing — HH801 at runtime
> npm install --legacy-peer-deps @nomicfoundation/hardhat-toolbox@5
> ```

**✅ Correct pattern — direct dependencies only**
> ```bash
> npm install --legacy-peer-deps \
>   @nomicfoundation/hardhat-ethers@^3.1.3 \
>   ethers@^6.16.0 \
>   chai@^4.2.0 \
>   "@types/chai@^4.2.0" \
>   "@types/mocha@>=9.1.0"
> ```
> _Source: `references/testing-patterns.md`_

---

**❌ `userDecryptEuint` 4th arg is string, not Signer**
> The 4th argument to `fhevm.userDecryptEuint` must be an `ethers.Signer` object. Passing `owner.address` (a string) causes a runtime error.
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> // ❌ owner.address is a string — wrong type
> const val = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, owner.address);
> ```

**✅ Correct pattern**
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> const val = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, owner); // Signer
> ```
> _Source: `references/testing-patterns.md`_

---

**❌ Zero handle — "Handle is not initialized"**
> Calling `userDecryptEuint` on a getter that returns `bytes32(0)` (no `set()` called yet) causes the TypeScript SDK to throw `"Handle is not initialized"` — no contract-level revert, confusing error surface.

**✅ Correct pattern — `FHE.isInitialized` guard in every getter**
> ```solidity
> // @fhevm/solidity@0.11.1
> function getValue() external view returns (euint32) {
>     require(FHE.isInitialized(_value), "Value not initialized"); // clear error before SDK sees zero handle
>     return _value;
> }
> ```
> _Source: `references/testing-patterns.md`_

---

**❌ Missing mock guard — tests silently run against live KMS**
> Without `fhevm.isMock` at the top of each test suite, a CI environment pointing at Sepolia will attempt real KMS decryption and produce misleading failures.

**✅ Correct pattern**
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> before(function () {
>   if (!fhevm.isMock) { throw new Error("This test suite cannot run on Sepolia"); }
> });
> ```
> _Source: `references/testing-patterns.md`_

---

### SDK

**❌ `@fhevm/sdk` does not exist on npm**
> This package name returns a 404 and crashes the install step. The correct packages are `@zama-fhe/sdk` (ERC-7984 tokens) and `@zama-fhe/relayer-sdk` (general contracts).
> ```typescript
> // ❌ 404 on npm
> import { ZamaSDK } from "@fhevm/sdk";
> ```

**✅ Correct package name**
> ```typescript
> // @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
> import { ZamaSDK } from "@zama-fhe/sdk"; // ERC-7984 tokens only
> ```
> _Sources: `references/frontend-integration.md`, `references/erc7984.md`_

---

**❌ Using `@zama-fhe/sdk` for non-token contracts**
> `@zama-fhe/sdk` exposes only ERC-7984 token methods (`shield`, `unshield`, `confidentialTransfer`, `decryptBalance`). It cannot drive arbitrary confidential contracts.
> ```typescript
> // ❌ @zama-fhe/sdk has no knowledge of custom contract functions
> const sdk = new ZamaSDK({ ... });
> sdk.myVotingContract.castVote(...); // does not exist
> ```

**✅ Correct pattern — use `@zama-fhe/relayer-sdk` for custom contracts**
> ```typescript
> // @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
> import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";
> const fhevm = await createInstance({ ...SepoliaConfig, network: provider, chainId: 11155111 });
> ```
> _Source: `references/frontend-integration.md`_

---

**❌ `fhevmjs` in new code**
> `fhevmjs` is a legacy SDK that will not receive updates for FHEVM v0.11+. Use `@zama-fhe/relayer-sdk` (general contracts) or `@zama-fhe/sdk` (ERC-7984 tokens) in all new code.
> ```typescript
> // ❌ Legacy — do not use
> import { createInstance } from "fhevmjs";
> ```
> _Sources: `references/frontend-integration.md`, `references/erc7984.md`_

---

### ERC-7984

**❌ Missing `ZamaEthereumConfig` when inheriting `ERC7984`**
> `ERC7984` does not register the FHE coprocessor. Omitting `ZamaEthereumConfig` causes FHE operations to revert with `ZamaProtocolUnsupported()` on mainnet and Sepolia.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Missing coprocessor registration
> contract MyToken is ERC7984 { ... }
> ```

**✅ Correct pattern — inherit both**
> ```solidity
> // @fhevm/solidity@0.11.1
> contract MyToken is ZamaEthereumConfig, ERC7984 {
>     constructor(string memory name_, string memory symbol_, string memory contractURI_)
>         ZamaEthereumConfig()
>         ERC7984(name_, symbol_, contractURI_)
>     {}
> }
> ```
> _Source: `references/erc7984.md`_

---

**❌ Ignoring the return value of `confidentialTransfer`**
> `confidentialTransfer` returns the **actual** transferred amount as `euint64`. When the sender's balance is insufficient, `ERC7984._update` saturates at zero via `FHESafeMath.tryDecrease` — no revert. Using the requested amount instead silently corrupts downstream accounting.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Assumes full amount was transferred
> _burn(from, requestedAmount);
> ```

**✅ Correct pattern — always use the return value**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint64 actualTransferred = token.confidentialTransfer(to, amount, inputProof);
> _processActualAmount(actualTransferred);
> ```
> _Source: `references/erc7984.md`_

---

## See Also

- [`references/access-control.md`](./access-control.md) — ACL patterns in depth
- [`references/input-proofs.md`](./input-proofs.md) — input proof and replay patterns
- [`references/fhe-operations.md`](./fhe-operations.md) — arithmetic, comparison, randomness
- [`references/encrypted-types.md`](./encrypted-types.md) — type selection and `euint4` caveat
- [`references/decryption-flows.md`](./decryption-flows.md) — user and public decryption
- [`references/testing-patterns.md`](./testing-patterns.md) — Hardhat mock environment
- [`references/frontend-integration.md`](./frontend-integration.md) — SDK selection and usage
- [`references/erc7984.md`](./erc7984.md) — ERC-7984 token patterns
