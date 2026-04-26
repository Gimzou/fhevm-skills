# Testing Patterns

## Overview

FHEVM Hardhat tests run in a mock FHE environment where all encryption and decryption is local — no KMS round-trip, no Sepolia required. The `fhevm` object from `"hardhat"` provides the full test API: encrypted input builders, user decryption helpers, public decryption helpers, and keypair utilities.

Key import points:
- `FhevmType` is exported from `@fhevm/hardhat-plugin`, **not** from `@fhevm/mock-utils`
- `fhevm.isMock` must be checked as the first guard in every suite
- `fhevm.encryptUint` / `encryptBool` / `encryptAddress` **do not exist** — use `createEncryptedInput` for all types

---

## Complete Example

See [`templates/hardhat-test.ts`](../templates/hardhat-test.ts) for the full annotated template. Key sections:

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
import { ethers, fhevm } from "hardhat";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

describe("MyContract", function () {
  // Mock guard MUST be first — tests cannot run on Sepolia
  before(function () {
    if (!fhevm.isMock) {
      throw new Error("This test suite cannot run on Sepolia");
    }
  });

  it("encrypt → store → userDecrypt cycle", async function () {
    const [owner] = await ethers.getSigners();
    const contract = await (await ethers.getContractFactory("MyContract")).deploy();
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    // Encrypt — createEncryptedInput is the only builder; no encryptUint helper
    const input = fhevm.createEncryptedInput(contractAddress, owner.address);
    input.add32(42);
    const { handles, inputProof } = await input.encrypt();
    // handles[0]: Uint8Array — pass directly as externalEuint32 parameter

    await contract.set(handles[0], inputProof);
    const handle = await contract.getCounter();

    // FHE.isInitialized guard in the contract prevents "Handle is not initialized" errors
    const value = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, owner);
    expect(value).to.equal(42n);
  });
});
```

---

## API Reference

### Encrypted input builder

```typescript
// Initialize — both addresses required to bind the proof to msg.sender
const input = fhevm.createEncryptedInput(contractAddress, signerAddress);

// Add values by type
input.addBool(true)          // → externalEbool
input.add8(val)              // → externalEuint8
input.add16(val)             // → externalEuint16
input.add32(val)             // → externalEuint32
input.add64(val)             // → externalEuint64
input.add128(val)            // → externalEuint128
input.add256(val)            // → externalEuint256
input.addAddress(addr)       // → externalEaddress

// Encrypt — returns one handle per added value, in add order
const { handles, inputProof } = await input.encrypt();
// handles: Uint8Array[] — ethers accepts Uint8Array for bytes32 parameters
// inputProof: Uint8Array — single proof covering all added values
```

### User decryption

```typescript
// Single-value helpers
fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, signer) → Promise<bigint>
fhevm.userDecryptEbool(handle, contractAddress, signer)                     → Promise<boolean>
fhevm.userDecryptEaddress(handle, contractAddress, signer)                  → Promise<string>

// Multi-value — manual EIP-712 keypair flow
fhevm.userDecrypt(
  [{ handle, contractAddress }, ...],
  privateKey,
  publicKey,
  signature,
  [contractAddress],
  signerAddress,
  startTimestamp,
  durationDays
)  → Promise<bigint[]>
```

### Public decryption (after `FHE.makePubliclyDecryptable` on-chain)

```typescript
fhevm.publicDecryptEuint(FhevmType.euint32, handle) → Promise<bigint>
fhevm.publicDecryptEbool(handle)                    → Promise<boolean>
fhevm.publicDecryptEaddress(handle)                 → Promise<string>
fhevm.publicDecrypt([handle1, handle2])             → Promise<(bigint|boolean|string)[]>
```

### Keypair helpers (manual EIP-712 flows)

```typescript
fhevm.generateKeypair()
// → { publicKey: string, privateKey: string }  (hex-encoded, NOT Uint8Array)

fhevm.createEIP712(publicKey, [contractAddress], startTimestamp, durationDays)
// → EIP-712 typed data object for signTypedData
```

---

## Common Patterns

### Mock guard placement

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
// Put the guard in a before() hook at the TOP of the describe block.
// Placing it inside individual it() blocks is error-prone — you'd skip some tests.
before(function () {
  if (!fhevm.isMock) {
    throw new Error("This test suite cannot run on Sepolia");
  }
});
```

### Encrypt-store-decrypt cycle

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
const input = fhevm.createEncryptedInput(contractAddress, owner.address);
input.add64(1_000_000n);
const { handles, inputProof } = await input.encrypt();

await token.deposit(handles[0], inputProof);
const handle = await token.getBalance();
const balance = await fhevm.userDecryptEuint(FhevmType.euint64, handle, contractAddress, owner);
```

### `FhevmType` usage

```typescript
// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
// Import from @fhevm/hardhat-plugin — NOT from @fhevm/mock-utils
import { FhevmType } from "@fhevm/hardhat-plugin";

// Match FhevmType to the Solidity type returned by the getter
const val8   = await fhevm.userDecryptEuint(FhevmType.euint8,   handle, addr, signer);
const val32  = await fhevm.userDecryptEuint(FhevmType.euint32,  handle, addr, signer);
const val64  = await fhevm.userDecryptEuint(FhevmType.euint64,  handle, addr, signer);
const bool_  = await fhevm.userDecryptEbool(handle, addr, signer);
const addr_  = await fhevm.userDecryptEaddress(handle, addr, signer);
```

### `FHE.isInitialized` guard in getters

```solidity
// @fhevm/solidity@0.11.1
// Add this to every getter that returns an encrypted handle.
// Without it: the getter returns bytes32(0) before any set() call,
// and TypeScript throws "Handle is not initialized" in userDecryptEuint
// with no contract-level signal — confusing for developers.
function getValue() external view returns (euint32) {
    require(FHE.isInitialized(_value), "Value not initialized");
    return _value;
}
```

---

## Anti-Patterns

**❌ `hardhat-toolbox@5` causes HH801 runtime error**
> `@nomicfoundation/hardhat-toolbox@5` lists all sub-packages as `peerDependencies`. With `--legacy-peer-deps`, peer deps are advisory and skipped — so toolbox is installed but its dependencies (hardhat-ethers, etc.) are not. Result: `HH801 Plugin ... not installed` at runtime even when toolbox is present.
>
> Do NOT install or import `hardhat-toolbox`. Use direct dependencies only:
> ```bash
> npm install --legacy-peer-deps \
>   @fhevm/solidity@0.11.1 \
>   @fhevm/hardhat-plugin@0.4.2 \
>   @fhevm/mock-utils@0.4.2 \
>   @zama-fhe/relayer-sdk@0.4.1 \
>   @nomicfoundation/hardhat-ethers@^3.1.3 \
>   ethers@^6.16.0 \
>   chai@^4.2.0 \
>   "@types/chai@^4.2.0" \
>   "@types/mocha@^10.0.0"
> ```
> `hardhat.config.ts` should import `"@fhevm/hardhat-plugin"` and `"@nomicfoundation/hardhat-ethers"` — never `hardhat-toolbox`.

---

**❌ `userDecryptEuint` 4th arg type mismatch**
> The 4th argument is an `ethers.Signer` object, NOT a string address. Passing `owner.address` (a string) causes a runtime error.
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> // ❌ Wrong — owner.address is a string, not a Signer
> const val = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, owner.address);
> ```

**✅ Correct pattern**
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> // ✅ Pass the Signer object directly
> const val = await fhevm.userDecryptEuint(FhevmType.euint32, handle, contractAddress, owner);
> ```

---

**❌ "Handle is not initialized" error from zero handle**
> Calling `userDecryptEuint` on a getter that returns `bytes32(0)` (because no `set()` was called) causes the TypeScript SDK to throw `"Handle is not initialized"`. There is no contract-level revert — the error surface is confusing.
>
> Add `FHE.isInitialized` to every getter:
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Reverts at the contract level with a clear message before the SDK sees a zero handle
> function getValue() external view returns (euint32) {
>     require(FHE.isInitialized(_value), "Value not initialized");
>     return _value;
> }
> ```
> In tests, test the uninitialized path explicitly so the error surface is documented.

---

**❌ Missing mock guard — tests silently run against live KMS**
> Without the `fhevm.isMock` check, a CI pipeline misconfigured to use Sepolia will attempt real KMS decryption, fail with opaque network errors, and produce misleading test output.
> ```typescript
> // @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
> // ✅ Always place this before any FHE test logic
> before(function () {
>   if (!fhevm.isMock) {
>     throw new Error("This test suite cannot run on Sepolia");
>   }
> });
> ```

---

## See Also

- [`templates/hardhat-test.ts`](../templates/hardhat-test.ts) — full annotated test template
- [`references/decryption-flows.md`](./decryption-flows.md) — user and public decryption API detail
- [`references/encrypted-types.md`](./encrypted-types.md) — `FhevmType` enum values
- [`_validation/test/confidentialCounter.ts`](../_validation/test/confidentialCounter.ts) — passing test covering set/increment/decrypt cycle
- [`_validation/test/decryptionFlows.ts`](../_validation/test/decryptionFlows.ts) — passing test covering both decryption flows
