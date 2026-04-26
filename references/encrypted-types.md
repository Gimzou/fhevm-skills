# Encrypted Types

## Overview

FHEVM exposes two categories of encrypted types:

**Internal types** (`euint*`, `eint*`, `ebool`, `eaddress`) — handles stored in contract state or used as local variables. They are `bytes32` handles under the hood; all FHE operations operate on internal handles.

**External input types** (`externalEuint*`, `externalEint*`, `externalEbool`, `externalEaddress`) — used exclusively as function parameters when the caller provides an encrypted value along with a ZK proof. They cannot be stored, operated on directly, or passed to ACL functions. Convert to an internal handle with `FHE.fromExternal()` before any use.

The two-category design exists because external inputs carry a ZK proof that must be verified before the ciphertext may participate in on-chain FHE operations. `FHE.fromExternal()` performs that verification and returns an internal handle.

---

## Complete Example

```solidity
// @fhevm/solidity@0.11.1
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint8, euint32, euint64, ebool, eaddress,
         externalEuint32, externalEaddress } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Demonstrates internal types in state + external types as function parameters.
contract TypeDemo is ZamaEthereumConfig {
    // Internal types in state — smallest type that fits the value range
    euint8   private _percentage;   // 0–255: fits in 8 bits
    euint32  private _counter;      // fits in 32 bits
    euint64  private _tokenBalance; // token amounts need 64 bits
    ebool    private _flag;
    eaddress private _recipient;

    // External types as function parameters — always paired with inputProof
    function setCounter(externalEuint32 encInput, bytes calldata inputProof) external {
        // fromExternal: verifies ZK proof + grants allowTransient(v, msg.sender)
        euint32 v = FHE.fromExternal(encInput, inputProof);
        // isSenderAllowed: defense-in-depth on the internal handle (not externalEuint32)
        require(FHE.isSenderAllowed(v), "Sender not authorized");
        FHE.allowThis(v);
        FHE.allow(v, msg.sender);
        _counter = v;
    }

    function setRecipient(externalEaddress encAddr, bytes calldata inputProof) external {
        eaddress a = FHE.fromExternal(encAddr, inputProof);
        require(FHE.isSenderAllowed(a), "Sender not authorized");
        FHE.allowThis(a);
        FHE.allow(a, msg.sender);
        _recipient = a;
    }

    function getCounter() external view returns (euint32) {
        return _counter;
    }
}
```

---

## API Reference

### Internal types

| Solidity type | `FhevmType` enum value | Bit width | Notes |
|---------------|------------------------|-----------|-------|
| `ebool`       | `FhevmType.ebool`      | 1         | Encrypted boolean |
| `euint8`      | `FhevmType.euint8`     | 8         | |
| `euint16`     | `FhevmType.euint16`    | 16        | |
| `euint32`     | `FhevmType.euint32`    | 32        | |
| `euint64`     | `FhevmType.euint64`    | 64        | Recommended for token amounts |
| `euint128`    | `FhevmType.euint128`   | 128       | |
| `euint256`    | `FhevmType.euint256`   | 256       | Highest gas cost |
| `eint8`       | `FhevmType.eint8`      | 8         | Signed |
| `eint16`      | `FhevmType.eint16`     | 16        | Signed |
| `eint32`      | `FhevmType.eint32`     | 32        | Signed |
| `eint64`      | `FhevmType.eint64`     | 64        | Signed |
| `eint128`     | `FhevmType.eint128`    | 128       | Signed |
| `eint256`     | `FhevmType.eint256`    | 256       | Signed |
| `eaddress`    | `FhevmType.eaddress`   | 160       | Encrypted Ethereum address |
| ~~`euint4`~~  | `FhevmType.euint4`     | 4         | **No Solidity type** — TypeScript enum only; using `euint4` in Solidity causes a compile error |

### External input types

Mirror of internal types, used as function parameters only:
`externalEbool`, `externalEuint8`–`externalEuint256`, `externalEint8`–`externalEint256`, `externalEaddress`

All external input types must be paired with `bytes calldata inputProof` and converted via `FHE.fromExternal()` before any use.

### Conversion functions

```solidity
FHE.fromExternal(encInput, inputProof)   // externalEuintX → euintX  (verifies ZK proof)
FHE.asEuint8(plainScalar)               // uint → euint8
FHE.asEuint32(plainScalar)              // uint → euint32
// ...asEuint16, asEuint64, asEuint128, asEuint256, asEbool, asEaddress
```

---

## Common Patterns

### Type selection by value range

```solidity
// @fhevm/solidity@0.11.1
euint8  private _percentage;  // 0–100 fits in 8 bits — cheapest
euint64 private _balance;     // token amounts often exceed 32-bit range
```

Gas cost scales with bit width. Always use the smallest type that correctly represents the value's range.

### External-to-internal conversion

```solidity
// @fhevm/solidity@0.11.1
function store(externalEuint64 encAmt, bytes calldata inputProof) external {
    euint64 v = FHE.fromExternal(encAmt, inputProof);  // ZK proof verified here
    require(FHE.isSenderAllowed(v), "Sender not authorized");
    FHE.allowThis(v);
    FHE.allow(v, msg.sender);
    _balance = v;
}
```

---

## Anti-Patterns

**❌ Using oversized encrypted types**
> `euint256` costs significantly more gas than `euint8`. Always use the smallest type that fits the value's range.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Wasteful — percentage fits in 8 bits
> euint256 private _percentage;
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Cheapest type for the value range
> euint8 private _percentage;
> ```

---

**❌ Unnecessary `FHE.asEuintXX()` wrapping for scalar arithmetic**
> Passing a scalar directly is cheaper than wrapping it first.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Wasteful
> x = FHE.add(x, FHE.asEuint32(42));
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Scalar overload — no wrapping needed
> x = FHE.add(x, 42);
> ```

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
> // ✅ Use euint8 (smallest available unsigned type) in Solidity
> euint8 private _nibble;
> ```
> In TypeScript tests, `FhevmType.euint4` is valid for `add4()` on `RelayerEncryptedInput`.

---

## See Also

- [`references/access-control.md`](./access-control.md) — ACL grants required when storing encrypted state
- [`references/fhe-operations.md`](./fhe-operations.md) — operations available on each type
- [`references/input-proofs.md`](./input-proofs.md) — external input ZK proof flow
- [`references/testing-patterns.md`](./testing-patterns.md) — `FhevmType` enum usage in tests
