// @fhevm/hardhat-plugin@0.4.2 | @zama-fhe/relayer-sdk@0.4.1
//
// Standalone Hardhat test template — covers the full encrypt → store → user-decrypt cycle.
// Copy this file to _validation/test/ and run: npm run test
//
// Requirements:
//   hardhat.config.ts must import "@fhevm/hardhat-plugin" and "@nomicfoundation/hardhat-ethers"
//   Do NOT use hardhat-toolbox — it causes HH801 errors with --legacy-peer-deps (see Anti-Patterns)
//
import { ethers, fhevm } from "hardhat";
import { expect } from "chai";
import { FhevmType } from "@fhevm/hardhat-plugin";

describe("HardhatTestTemplate", function () {
  // ─── Mock guard ───────────────────────────────────────────────────────────
  // This MUST be the first statement in the suite.
  // Tests relying on mock FHE cannot run on Sepolia — the KMS is live there.
  before(function () {
    if (!fhevm.isMock) {
      throw new Error("This test suite cannot run on Sepolia");
    }
  });

  it("deploy → encrypt → set → userDecryptEuint → assert 42n", async function () {
    const [owner] = await ethers.getSigners();

    // ─── Deploy ──────────────────────────────────────────────────────────────
    const Factory = await ethers.getContractFactory("ConfidentialCounter");
    const contract = await Factory.deploy();
    await contract.waitForDeployment();
    const contractAddress = await contract.getAddress();

    // ─── Encrypt ─────────────────────────────────────────────────────────────
    // fhevm.encryptUint / encryptBool / encryptAddress do NOT exist in @fhevm/hardhat-plugin@0.4.2.
    // Use createEncryptedInput builder for all types.
    const input = fhevm.createEncryptedInput(contractAddress, owner.address);
    input.add32(42);                                           // add8 / add16 / add32 / add64 / add128 / add256 / addBool / addAddress
    const { handles, inputProof } = await input.encrypt();
    // handles: Uint8Array[] — one per added value (NOT string[])
    // Pass handles[0] where the contract expects externalEuint32

    // ─── Store on-chain ──────────────────────────────────────────────────────
    await contract.set(handles[0], inputProof);

    // ─── Read handle ─────────────────────────────────────────────────────────
    const handle = await contract.getCounter();

    // ─── User-decrypt ────────────────────────────────────────────────────────
    // Signature: userDecryptEuint(type, handle, contractAddress, signer)
    // 4th arg is an ethers Signer object — NOT owner.address (string)
    const decrypted = await fhevm.userDecryptEuint(
      FhevmType.euint32,   // FhevmType enum from @fhevm/hardhat-plugin (not @fhevm/mock-utils)
      handle,
      contractAddress,
      owner                // Signer, not owner.address
    );

    expect(decrypted).to.equal(42n);
  });
});
