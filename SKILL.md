---
name: fhevm
description: Build confidential smart contracts on Ethereum using Zama FHEVM — encrypted types, FHE operations, access control, decryption flows, testing, and ERC-7984 tokens
---

FHEVM runs FHE operations off-chain on a coprocessor; results are opaque `bytes32` handles stored on-chain. Handles require explicit ACL grants (`FHE.allowThis`, `FHE.allow`) before decryption succeeds. See `references/fhevm-overview.md` for the full architecture.

## Install

```bash
# Base stack — Hardhat + FHEVM
npm install --legacy-peer-deps \
  @fhevm/solidity@0.11.1 \
  @fhevm/hardhat-plugin@0.4.2 \
  @fhevm/mock-utils@0.4.2 \
  @zama-fhe/relayer-sdk@0.4.1 \
  @nomicfoundation/hardhat-ethers@^3.1.3 \
  ethers@^6.16.0 \
  chai@^4.2.0 \
  "@types/chai@^4.2.0" \
  "@types/mocha@>=9.1.0"
```

```bash
# ERC-7984 extended — confidential tokens
npm install --legacy-peer-deps \
  @openzeppelin/confidential-contracts@0.4.0 \
  @openzeppelin/contracts@5.6.1 \
  @zama-fhe/sdk@2.2.0
```

## Minimal Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// @fhevm/solidity@0.11.1
import { FHE, euint32, externalEuint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// Demonstrates: external input + ZK proof verification, overflow-guarded arithmetic,
// ACL dual-grant pattern (allowThis + allow), isInitialized getter guard, and the
// per-user mapping pattern that avoids the ACL overwrite footgun
// (see references/access-control.md — Anti-Patterns).
contract ConfidentialCounter is ZamaEthereumConfig {
    // Per-user mapping: each caller has their own isolated handle.
    // A single-slot euint32 state leaves every prior handle permanently ACL'd
    // (FHE.disallow() does not exist). The mapping confines the leak to the
    // user's own history.
    mapping(address => euint32) private _counters;

    // Set the caller's counter to a caller-supplied encrypted value.
    function set(externalEuint32 encInput, bytes calldata inputProof) external {
        // fromExternal: verifies ZK proof + grants allowTransient(v, msg.sender)
        euint32 v = FHE.fromExternal(encInput, inputProof);
        // isSenderAllowed: defense-in-depth — must be called on the internal handle,
        // NOT on externalEuint32 (that causes a compile error)
        require(FHE.isSenderAllowed(v), "Sender not authorized");
        FHE.allowThis(v);          // required — omitting silently breaks user decryption
        FHE.allow(v, msg.sender);  // grants caller persistent access to decrypt
        _counters[msg.sender] = v;
    }

    // Increment the caller's counter by 1 with an overflow guard.
    // On overflow the previous value is preserved (the new value is discarded).
    function increment() external {
        euint32 current = _counters[msg.sender];
        require(FHE.isInitialized(current), "Counter not initialized");
        euint32 newVal   = FHE.add(current, 1);
        // Overflow guard: if newVal < current, the add wrapped — keep old value
        ebool   overflowed = FHE.lt(newVal, current);
        euint32 result     = FHE.select(overflowed, current, newVal);
        FHE.allowThis(result);
        FHE.allow(result, msg.sender);
        _counters[msg.sender] = result;
    }

    // Return the caller's encrypted counter handle. Reverts if never set.
    // Without isInitialized guard, callers receive bytes32(0) and TypeScript throws
    // "Handle is not initialized" on userDecryptEuint — no contract-level signal.
    function getCounter() external view returns (euint32) {
        require(FHE.isInitialized(_counters[msg.sender]), "Counter not initialized");
        return _counters[msg.sender];
    }
}
```

## Quick Start by Role

| Role | Building | Start here |
|------|----------|-----------|
| Solidity / contract dev | Confidential contract logic (FHE ops, access control) | `references/encrypted-types.md` → `references/fhe-operations.md` → `references/access-control.md` |
| Frontend / Web3 dev | Decryption UI, input encryption in the browser | `references/frontend-integration.md` → `references/decryption-flows.md` |
| Full-stack dApp dev | Complete FHE-enabled application | `references/fhevm-overview.md`, then the table below |
| DeFi / token dev | Confidential ERC-7984 token | `references/erc7984.md` → `templates/confidential-erc7984.sol` |

## Reference Files

| When you need to… | Load |
|-------------------|------|
| Understand FHEVM architecture and handles | `references/fhevm-overview.md` |
| Work with encrypted types (euint*, eint*, ebool, eaddress) | `references/encrypted-types.md` |
| Perform FHE operations (arithmetic, comparison, conditional) | `references/fhe-operations.md` |
| Implement access control (allow, allowThis, allowTransient) | `references/access-control.md` |
| Handle encrypted user inputs (input proofs, isSenderAllowed) | `references/input-proofs.md` |
| Implement decryption (user EIP-712 or public Gateway flow) | `references/decryption-flows.md` |
| Write Hardhat tests for FHEVM contracts | `references/testing-patterns.md` |
| Build frontend integration (relayer-sdk or @zama-fhe/sdk) | `references/frontend-integration.md` |
| Implement ERC-7984 confidential tokens | `references/erc7984.md` |
| Review security anti-patterns and fixes | `references/anti-patterns.md` |

## Version

Targets `@fhevm/solidity@0.11.1` (npm stable, Mar 2026). `v0.12.0` is GitHub-only — not yet on npm. When 0.12.0 lands on npm, load `references/v0.12/` for updated patterns.
