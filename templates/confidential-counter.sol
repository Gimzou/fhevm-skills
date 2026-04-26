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
