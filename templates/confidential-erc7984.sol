// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// @fhevm/solidity@0.11.1
import { FHE, euint64, externalEuint64 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { ERC7984 } from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";

// ERC-7984 confidential token template.
// Inherits ZamaEthereumConfig first (registers the FHE coprocessor — required on mainnet,
// Sepolia, and local) and ERC7984 second (core transfer/balance logic). The linearization
// order means ZamaEthereumConfig() runs BEFORE ERC7984(name,symbol,contractURI) in C3, so
// the coprocessor is registered before any constructor-time FHE op a future base version
// might introduce.
//
// ACL note: ERC7984._update handles allowThis + allow(balance, holder) for every
// balance change, so no manual ACL calls are needed in shield/unshield.
contract ConfidentialERC7984 is ZamaEthereumConfig, ERC7984 {
    // contractURI_ follows ERC-7572; pass "" for local/test deployments.
    // Initializer order mirrors the inheritance list: ZamaEthereumConfig() first, then ERC7984(...).
    constructor(string memory name_, string memory symbol_, string memory contractURI_)
        ZamaEthereumConfig()
        ERC7984(name_, symbol_, contractURI_)
    {}

    // Mint confidential tokens to msg.sender (deposit / shield).
    // Returns the euint64 handle of the actual minted amount (may be less than
    // requested if an internal overflow occurred — use the return value, not the input).
    function shield(externalEuint64 encryptedAmount, bytes calldata inputProof)
        external
        returns (euint64)
    {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        require(FHE.isSenderAllowed(amount), "Caller lacks ACL access");
        return _mint(msg.sender, amount);
    }

    // Burn encrypted tokens from msg.sender (withdrawal / unshield).
    // Caller must pass an on-chain euint64 handle they are ACL-allowed for
    // (e.g. the handle returned by confidentialBalanceOf(msg.sender)).
    //
    // Security note: this wrapper is intentionally minimal — it trusts the caller's
    // ACL-allowed handle. OZ's _update → tryDecrease saturates safely on underflow, so
    // passing any handle you are allowed on at most transfers your own balance. If you
    // need proof-bound unshielding, accept `externalEuint64 + inputProof` instead and
    // route through FHE.fromExternal + FHE.isSenderAllowed (see shield() above).
    //
    // Returns the euint64 handle of the actual burned amount.
    function unshield(euint64 amount) external returns (euint64) {
        require(FHE.isAllowed(amount, msg.sender), "Caller lacks ACL access");
        return _burn(msg.sender, amount);
    }
}
