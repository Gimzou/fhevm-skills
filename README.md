# FHEVM Skills for AI Coding Agents

Drop-in skill for AI coding agents (Claude Code, Cursor, …) that teaches them how to write correct [Zama FHEVM](https://docs.zama.ai/protocol) confidential smart contracts — encrypted types, FHE operations, access control, decryption flows, testing, and ERC-7984 tokens.

## Install

```bash
# Pick your agent
npx skills add Gimzou/fhevm-skills --agent claude-code
npx skills add Gimzou/fhevm-skills --agent cursor
```

## What you get

| File | Role |
|------|------|
| `SKILL.md` | Master file — architecture overview, install commands, minimal working contract, routing table |
| `references/fhevm-overview.md` | Coprocessor model, Gateway, KMS, supported chains |
| `references/encrypted-types.md` | `euint*`, `eint*`, `ebool`, `eaddress`, external inputs |
| `references/fhe-operations.md` | Arithmetic, comparison, bitwise, conditional, randomness |
| `references/access-control.md` | `allow`, `allowThis`, `allowTransient`, ACL patterns |
| `references/input-proofs.md` | `fromExternal`, `isSenderAllowed` guard |
| `references/decryption-flows.md` | User decryption (EIP-712) + public decryption |
| `references/testing-patterns.md` | Hardhat mock tests, encrypt/decrypt helpers |
| `references/frontend-integration.md` | `@zama-fhe/relayer-sdk` (general) + `@zama-fhe/sdk` (ERC-7984) |
| `references/erc7984.md` | OpenZeppelin confidential token standard |
| `references/anti-patterns.md` | 25 anti-patterns across 8 domains with fixes |
| `templates/confidential-counter.sol` | Minimal working contract (copy and compile) |
| `templates/confidential-erc7984.sol` | ERC-7984 token template |
| `templates/hardhat-test.ts` | Test harness pattern |

## Version targeting

Targets `@fhevm/solidity@0.11.1` (npm stable). When `0.12.0` lands on npm, a `references/v0.12/` folder will be published alongside this one. Agents can install both in parallel.

## Supported agents

| Agent | Status |
|-------|--------|
| Claude Code | Verified (Zama Developer Program S2 validation) |
| Cursor | Verified (installer path confirmed: `.agents/skills/fhevm/`) |

Other skills.sh-supported agents (Windsurf, Gemini CLI, Roo, Kilo, …) should resolve via `npx skills add` per the [agent-to-directory mapping](https://github.com/vercel-labs/skills#agents), but have not been explicitly tested.

## License

MIT