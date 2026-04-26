# Frontend Integration

## Overview

Zama provides two distinct SDKs for client-side FHEVM integration. **Choosing the wrong one is the most common frontend mistake.**

| Package | Scope | Use for |
|---------|-------|---------|
| `@zama-fhe/relayer-sdk@0.4.1` | General — any confidential contract | Voting, gaming, custom logic, any non-token contract |
| `@zama-fhe/sdk@2.2.0` | ERC-7984 token operations only | `shield`, `unshield`, `confidentialTransfer`, balance query |
| `@zama-fhe/react-sdk` | React hooks wrapping `@zama-fhe/sdk` | React dApps doing ERC-7984 token operations |
| `fhevmjs` | **Legacy** — do not use | Nothing new |
| `@fhevm/sdk` | **Does not exist on npm (404)** | Nothing |

**Decision rule:** If your contract inherits `ERC7984`, use `@zama-fhe/sdk`. For everything else (custom encrypted contracts, voting, escrow, gaming), use `@zama-fhe/relayer-sdk` directly.

**Install:**
```bash
# ERC-7984 token frontend
npm install --legacy-peer-deps @zama-fhe/sdk@2.2.0

# Custom contracts (voting, gaming, arbitrary FHE)
npm install --legacy-peer-deps @zama-fhe/relayer-sdk@0.4.1
```
`--legacy-peer-deps` is required because both SDKs pin overlapping peer ranges that npm 7+ otherwise refuses to resolve.

---

## Complete Example

End-to-end `@zama-fhe/relayer-sdk` flow: initialize a `FhevmInstance`, encrypt an input bound to `(contractAddress, userAddress)`, then run a user-decryption round trip.

```typescript
// @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
import {
  createInstance,
  SepoliaConfig,        // preset FhevmInstanceConfig without `network`
  type FhevmInstance,
} from "@zama-fhe/relayer-sdk/web";
import { BrowserProvider } from "ethers";

// Initialize once per app session
async function initFhevm(provider: BrowserProvider): Promise<FhevmInstance> {
  const network = await provider.getNetwork();
  return createInstance({
    ...SepoliaConfig,           // fills contract addresses + relayerUrl for Sepolia
    network: provider,          // EIP-1193 provider or RPC URL string
    chainId: Number(network.chainId),
  });
}

// Encrypt a value for a specific contract + user address pair
async function encryptForContract(
  fhevm: FhevmInstance,
  contractAddress: string,
  userAddress: string,
  value: bigint
) {
  const input = fhevm.createEncryptedInput(contractAddress, userAddress);
  input.add64(value);           // use add8/16/32/64/128/256/Bool/Address as needed
  const encrypted = await input.encrypt();
  return encrypted;             // { handles: Uint8Array[], inputProof: Uint8Array }
}

// User decryption: re-encrypt with user's ML-KEM key via Gateway
async function userDecrypt(
  fhevm: FhevmInstance,
  handle: string,               // bytes32 hex handle from contract
  contractAddress: string,
  signer: any                   // ethers Signer
) {
  const userAddress = await signer.getAddress();
  const now = Math.floor(Date.now() / 1000);
  const { publicKey, privateKey } = fhevm.generateKeypair();
  const eip712 = fhevm.createEIP712(publicKey, [contractAddress], now, 10);
  const signature = await signer.signTypedData(
    eip712.domain,
    eip712.types,
    eip712.message
  );
  const results = await fhevm.userDecrypt(
    [{ handle, contractAddress }],
    privateKey,
    publicKey,
    signature,
    [contractAddress],
    userAddress,
    now,
    10
  );
  return results[handle];       // bigint cleartext
}
```

---

## API Reference

### `@zama-fhe/relayer-sdk` — `FhevmInstance`

Obtained via `createInstance(config: FhevmInstanceConfig)`.

- `createEncryptedInput(contractAddress: string, userAddress: string) → RelayerEncryptedInput`
  - `.add8/16/32/64/128/256(value: bigint)`, `.addBool(value: boolean)`, `.addAddress(value: string)`
  - `.encrypt() → Promise<{ handles: Uint8Array[], inputProof: Uint8Array }>`
- `generateKeypair() → { publicKey: string, privateKey: string }`
- `createEIP712(publicKey, contractAddresses, startTimestamp, durationDays) → EIP712TypedData`
- `userDecrypt(handles, privateKey, publicKey, signature, contractAddresses, userAddress, startTimestamp, durationDays) → Promise<Record<handle, bigint>>`
- `publicDecrypt(handles: string[]) → Promise<Record<handle, bigint>>`

**Preset configs** (Omit `network` and `chainId` — supply at call site):
- `SepoliaConfig` — Sepolia testnet
- `MainnetConfig` — Ethereum mainnet
- Import from `@zama-fhe/relayer-sdk/web` (browser) or `@zama-fhe/relayer-sdk/node` (Node.js)

### `@zama-fhe/sdk` — `ZamaSDK`

- `new ZamaSDK(config: ZamaSDKConfig)` — required fields: `relayer`, `signer`, `storage`
- `sdk.createToken(address: Address, wrapper?: Address) → Token` — write-capable token interface
- `sdk.createReadonlyToken(address: Address) → ReadonlyToken` — read-only (balance, ACL checks)
- `sdk.registry` — `WrappersRegistry` for listing ERC-7984 / ERC-20 pairs

### `@zama-fhe/sdk` — `RelayerWeb`

- `new RelayerWeb(config: RelayerWebConfig)` — browser Web Worker backend
  - `config.transports: Record<chainId, FhevmInstanceConfig>` — per-chain FHEVM config
  - `config.getChainId: () => Promise<number>` — called before each operation

### Storage backends (`@zama-fhe/sdk`)

- `IndexedDBStorage` — browser IndexedDB; persists credentials across sessions (recommended for production)
- `MemoryStorage` / `memoryStorage` — in-memory; credentials lost on page reload (use in tests)
- `ChromeSessionStorage` — `chrome.storage.session`; for MV3 extensions; survives service worker restarts

### Preset configs (`@zama-fhe/sdk`)

- `HardhatConfig` — local Hardhat node (`chainId: 31337`, `network: "http://127.0.0.1:8545"`)
- `SepoliaConfig` — Sepolia testnet
- `MainnetConfig` — Ethereum mainnet

---

## Common Patterns

### `@zama-fhe/sdk` — ERC-7984 token operations

Use `@zama-fhe/sdk` only for contracts inheriting `ERC7984`. It wraps the common token methods (`shield`, `unshield`, `confidentialTransfer`, `decryptBalance`) and handles relayer transport, storage, and EIP-712 signing internally.

```typescript
// @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
import {
  ZamaSDK,
  RelayerWeb,
  IndexedDBStorage,
  SepoliaConfig,
} from "@zama-fhe/sdk";
import type { GenericSigner } from "@zama-fhe/sdk";

// 1. Initialize ZamaSDK once per user session
function initZamaSDK(signer: GenericSigner): ZamaSDK {
  const relayer = new RelayerWeb({
    transports: {
      11155111: {              // Sepolia chain ID
        ...SepoliaConfig,
        network: window.ethereum,   // EIP-1193 provider
      },
    },
    getChainId: async () => {
      const chainId = await window.ethereum.request({ method: "eth_chainId" });
      return parseInt(chainId, 16);
    },
  });

  return new ZamaSDK({
    relayer,
    signer,                          // viem or ethers signer wrapped as GenericSigner
    storage: new IndexedDBStorage(), // persists FHE credentials across sessions
  });
}

// 2. Token operations — shield / unshield / confidentialTransfer / decryptBalance
async function tokenOperations(sdk: ZamaSDK, tokenAddress: string, recipient: string) {
  const token = sdk.createToken(tokenAddress);

  await token.shield(1000n);                         // deposit ERC-20 → confidential balance
  const balance = await token.decryptBalance();      // bigint cleartext balance
  await token.confidentialTransfer(recipient, 200n); // encrypted transfer
  await token.unshield(100n);                        // withdraw confidential → ERC-20
}
```

### `@zama-fhe/relayer-sdk` for custom contracts

```typescript
// @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";

const fhevm = await createInstance({
  ...SepoliaConfig,
  network: window.ethereum,
  chainId: 11155111,
});

// Encrypt a value bound to a specific contract + user
const input = fhevm.createEncryptedInput(contractAddress, userAddress);
input.add32(42n);
const { handles, inputProof } = await input.encrypt();

// Call your custom contract
await myContract.myEncryptedFunction(handles[0], inputProof);
```

### Per-chain transport config (multi-chain dApp)

```typescript
// @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
import { RelayerWeb, SepoliaConfig, MainnetConfig } from "@zama-fhe/sdk";

const relayer = new RelayerWeb({
  transports: {
    1:         { ...MainnetConfig,  network: window.ethereum },
    11155111:  { ...SepoliaConfig,  network: window.ethereum },
  },
  getChainId: async () => parseInt(await window.ethereum.request({ method: "eth_chainId" }), 16),
});
```

---

## Anti-Patterns

**❌ `@fhevm/sdk` — package does not exist on npm**
> This package name returns a 404. Using it crashes the install step.
> ```typescript
> // ❌ 404 on npm — will crash npm install
> import { ZamaSDK } from "@fhevm/sdk";
> ```

**✅ Correct package name**
> ```typescript
> // @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
> import { ZamaSDK } from "@zama-fhe/sdk";
> ```

---

**❌ Using `@zama-fhe/sdk` for non-token contracts**
> `@zama-fhe/sdk` exposes only ERC-7984 token methods (`shield`, `unshield`, `confidentialTransfer`, `decryptBalance`). Attempting to use it for a voting contract, game, or any other custom confidential contract will not expose the contract's functions — you need `@zama-fhe/relayer-sdk` for arbitrary contracts.
> ```typescript
> // ❌ @zama-fhe/sdk does not know about your custom contract's functions
> const sdk = new ZamaSDK({ ... });
> sdk.myVotingContract.castVote(...); // ❌ does not exist
> ```

**✅ Correct: use `@zama-fhe/relayer-sdk` for custom contracts**
> ```typescript
> // @zama-fhe/sdk@2.2.0 | @zama-fhe/relayer-sdk@0.4.1
> import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";
> const fhevm = await createInstance({ ...SepoliaConfig, network: provider, chainId: 11155111 });
> const input = fhevm.createEncryptedInput(contractAddress, userAddress);
> ```

---

**❌ Using `fhevmjs` in new code**
> `fhevmjs` is a legacy SDK. All new integrations should use `@zama-fhe/relayer-sdk` (general) or `@zama-fhe/sdk` (ERC-7984 tokens). `fhevmjs` will not receive updates aligned with FHEVM v0.11+.
> ```typescript
> // ❌ Legacy — do not use in new code
> import { createInstance } from "fhevmjs";
> ```

---

## See Also

- `references/erc7984.md` — Solidity-side ERC-7984 API and patterns
- `references/decryption-flows.md` — user decryption and public decryption flows
- [`@zama-fhe/relayer-sdk` source](https://github.com/zama-ai/fhevm-relayer-sdk)
- [`@zama-fhe/sdk` source](https://github.com/zama-ai/fhevm-sdk)
- [Zama FHEVM documentation](https://docs.zama.ai/fhevm)