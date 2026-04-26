# FHE Operations

## Overview

All FHE operations are called as `FHE.<op>(args)` and return a new encrypted handle. They never reveal plaintext — results are ciphertexts that can be stored, passed to further operations, or decrypted by authorized parties via the gateway.

Operation families:
- **Arithmetic** — `add`, `sub`, `mul`, `div`, `rem`, `neg`
- **Comparison** — return `ebool`: `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `min`, `max`
- **Logical** — `and`, `or`, `xor`, `not`
- **Bitwise shifts** — `shl`, `shr`, `rotl`, `rotr`
- **Randomness** — `randEbool`, `randEuint8`…`randEuint256`; each `randEuintNN` has a bounded overload `randEuintNN(upperBound)`
- **Conditional** — `select` (encrypted ternary)
- **Type conversion** — `asEuintXX`, `asEbool`, `asEaddress`, `fromExternal`

FHE arithmetic wraps on overflow — there is no hardware exception. Callers must apply an explicit overflow guard using `FHE.select` + `FHE.lt` (see Anti-Patterns).

---

## Complete Example

```solidity
// @fhevm/solidity@0.11.1
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, euint64, ebool, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Exercises arithmetic, comparison, conditional (FHE.select), and overflow guard.
contract OperationsDemo is ZamaEthereumConfig {
    euint64 private _supply;
    euint32 private _counter;

    // Mint: add to supply with overflow guard.
    // Seeds _supply on first mint so subsequent FHE.add/lt/select have a valid handle.
    function mint(externalEuint32 encAmt, bytes calldata inputProof) external {
        euint32 v = FHE.fromExternal(encAmt, inputProof);
        require(FHE.isSenderAllowed(v), "Sender not authorized");

        // Widen to euint64 before adding to avoid type mismatch
        euint64 amt64 = FHE.asEuint64(v);

        euint64 result;
        if (!FHE.isInitialized(_supply)) {
            // First mint — seed supply directly; 0 + amt64 cannot wrap.
            result = amt64;
        } else {
            // Overflow guard: if newSupply < _supply, an overflow occurred — keep old value
            euint64 newSupply  = FHE.add(_supply, amt64);
            ebool   overflowed = FHE.lt(newSupply, _supply);
            result             = FHE.select(overflowed, _supply, newSupply);
        }

        FHE.allowThis(result);
        FHE.allow(result, msg.sender);
        _supply = result;
    }

    // Increment counter by a scalar (no external input needed — scalar is plaintext).
    // Seeds _counter on first bump for the same reason as mint().
    function bump(uint32 step) external {
        euint32 result;
        if (!FHE.isInitialized(_counter)) {
            result = FHE.asEuint32(step);
        } else {
            euint32 newVal   = FHE.add(_counter, step); // scalar overload — cheaper than asEuintXX
            ebool overflowed = FHE.lt(newVal, _counter);
            result           = FHE.select(overflowed, _counter, newVal);
        }

        FHE.allowThis(result);
        FHE.allow(result, msg.sender);
        _counter = result;
    }

    function getSupply() external view returns (euint64) {
        require(FHE.isInitialized(_supply), "Supply not initialized");
        return _supply;
    }

    function getCounter() external view returns (euint32) {
        require(FHE.isInitialized(_counter), "Counter not initialized");
        return _counter;
    }
}
```

---

## API Reference

### Arithmetic

```solidity
FHE.add(a, b)                     // euintX + euintX → euintX  (wraps on overflow — guard required)
FHE.add(a, plainScalar)           // euintX + uint → euintX    (scalar overload — cheaper)
FHE.sub(a, b)                     // euintX - euintX → euintX
FHE.sub(a, plainScalar)           // euintX - uint → euintX
FHE.mul(a, b)                     // euintX * euintX → euintX
FHE.mul(a, plainScalar)           // euintX * uint → euintX
FHE.div(a, plainDivisor)          // euintX / uint → euintX    (plaintext divisor only)
FHE.rem(a, plainDivisor)          // euintX % uint → euintX    (plaintext divisor only)
FHE.neg(a)                        // euintX → euintX
FHE.min(a, b)                     // euintX, euintX → euintX
FHE.max(a, b)                     // euintX, euintX → euintX
```

### Comparison (all return `ebool`)

```solidity
FHE.eq(a, b)                      // euintX == euintX → ebool
FHE.ne(a, b)                      // euintX != euintX → ebool
FHE.lt(a, b)                      // euintX < euintX → ebool   (not "lte")
FHE.le(a, b)                      // euintX <= euintX → ebool  (not "lte")
FHE.gt(a, b)                      // euintX > euintX → ebool   (not "gte")
FHE.ge(a, b)                      // euintX >= euintX → ebool  (not "gte")
```

### Logical

```solidity
FHE.and(a, b)                     // ebool & ebool → ebool
FHE.or(a, b)                      // ebool | ebool → ebool
FHE.xor(a, b)                     // ebool ^ ebool → ebool
FHE.not(a)                        // !ebool → ebool
```

### Bitwise

```solidity
FHE.shl(a, shift)                 // euintX << uint → euintX
FHE.shr(a, shift)                 // euintX >> uint → euintX
FHE.rotl(a, n)                    // rotate left
FHE.rotr(a, n)                    // rotate right
```

### Randomness

```solidity
FHE.randEbool()                   // → ebool
FHE.randEuint8()                  // → euint8
FHE.randEuint16()                 // → euint16
FHE.randEuint32()                 // → euint32
FHE.randEuint64()                 // → euint64
FHE.randEuint128()                // → euint128
FHE.randEuint256()                // → euint256
FHE.randEuint32(upperBound)       // → euint32, value in [0, upperBound)  (bounded overload — same name, extra arg; variants for all sizes)
                                  //   ⚠️ upperBound MUST be a power of two; otherwise the FHEVMExecutor reverts with NotPowerOfTwo()
```

### Conditional

```solidity
FHE.select(cond, valueIfTrue, valueIfFalse)  // ebool, euintX, euintX → euintX (encrypted ternary)
```

### Type conversion

```solidity
FHE.asEuint8(plainScalar)         // uint → euint8
FHE.asEuint32(plainScalar)        // uint → euint32
// ...asEuint16, asEuint64, asEuint128, asEuint256, asEbool, asEaddress
FHE.fromExternal(enc, proof)      // externalEuintX → euintX  (with ZK proof verification)
```

---

## Common Patterns

### Overflow guard (required for any arithmetic that can wrap)

```solidity
// @fhevm/solidity@0.11.1
// ⚠️ Import ebool alongside the numeric type — comparison ops (lt, gt, eq, …) return ebool.
// import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
// Pattern: compute → detect overflow → select old or new value
euint32 newVal   = FHE.add(a, b);
ebool overflowed = FHE.lt(newVal, a);        // if newVal < a, the add wrapped
euint32 result   = FHE.select(overflowed, a, newVal); // keep a on overflow (saturate)
```

### Encrypted ternary (`FHE.select`)

```solidity
// @fhevm/solidity@0.11.1
// ⚠️ Import ebool — comparison ops (ge, lt, eq, …) return ebool.
// import { FHE, euint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
// Equivalent to: cond ? valueIfTrue : valueIfFalse — without revealing cond
ebool  isMax   = FHE.ge(balance, cap);
euint64 capped = FHE.select(isMax, cap, balance);
```

### Random bounded value

```solidity
// @fhevm/solidity@0.11.1
// Draw a random number in [0, 128) — on-chain randomness, not user-controllable.
// randEuintNN has two overloads: the unbounded variant and randEuintNN(upperBound).
// ⚠️ upperBound MUST be a power of two (128, 256, 1024, ...). A non-power-of-two
//    like 100 triggers FHEVMExecutor.NotPowerOfTwo() on every call.
euint32 roll = FHE.randEuint32(128);
FHE.allowThis(roll);
FHE.allow(roll, msg.sender);
```

---

## Anti-Patterns

**❌ FHE arithmetic overflow without a select-guard**
> FHE arithmetic wraps silently on overflow. There is no hardware exception or revert. Without a guard, the result is incorrect and no error is raised.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Vulnerable — totalSupply can wrap silently
> totalSupply = FHE.add(totalSupply, mintedAmount);
> ```

**✅ Correct pattern — select-guard**
> ```solidity
> // @fhevm/solidity@0.11.1
> euint64 newSupply  = FHE.add(totalSupply, mintedAmount);
> ebool   overflowed = FHE.lt(newSupply, totalSupply);
> totalSupply        = FHE.select(overflowed, totalSupply, newSupply); // saturate on overflow
> ```

---

**❌ `FHE.randEuintNN(upperBound)` with a non-power-of-two bound**
> The bounded-random overloads require `upperBound` to be a power of two (`2, 4, 8, ..., 128, 256, ...`). Any other value — including "natural" choices like `100` or `1000` — reverts every call with `FHEVMExecutor.NotPowerOfTwo()`.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Reverts at every call with NotPowerOfTwo()
> euint32 roll = FHE.randEuint32(100);
> ```

**✅ Correct pattern — use a power-of-two bound, then modulo-reduce in plaintext space if needed**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ 128 is a power of two
> euint32 roll = FHE.randEuint32(128);
> // If you need range [0, 100), draw the full range and rely on `FHE.rem`/`FHE.select`
> // patterns — never call the bounded overload with a non-power-of-two upperBound.
> ```

---

**❌ Loop conditions on encrypted booleans**
> `ebool` is a ciphertext handle — it is not an EVM boolean. Using it as a loop condition or in an `if` statement does not work; the EVM cannot branch on ciphertext.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Does not compile / does not work — ebool is not a Solidity bool
> while (FHE.lt(x, encryptedMax)) { ... }
> ```

**✅ Correct pattern — use `FHE.select` instead of branching**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Compute both branches, then select based on the encrypted condition
> euint32 incremented = FHE.add(x, 1);
> ebool   atMax       = FHE.ge(x, encryptedMax);
> x = FHE.select(atMax, x, incremented); // stay at x if at max, else increment
> ```

---

**❌ Unnecessary `FHE.asEuintXX(scalar)` wrapping**
> Wrapping a plaintext scalar in an encrypted type before arithmetic is wasteful. Use the scalar overload directly.
> ```solidity
> // @fhevm/solidity@0.11.1
> // ❌ Unnecessary conversion
> euint32 result = FHE.add(x, FHE.asEuint32(1));
> ```

**✅ Correct pattern**
> ```solidity
> // @fhevm/solidity@0.11.1
> // ✅ Scalar overload — cheaper and cleaner
> euint32 result = FHE.add(x, 1);
> ```

---

## See Also

- [`references/encrypted-types.md`](./encrypted-types.md) — type widths and selection
- [`references/access-control.md`](./access-control.md) — ACL grants after storing operation results
- [`templates/confidential-counter.sol`](../templates/confidential-counter.sol) — overflow guard in context
