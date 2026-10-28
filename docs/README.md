# Docs

Most documents here are in Chinese.

## Repository layout

| Path | Contents |
|---|---|
| `core/` | `UniPassCore` Swift package shared by both apps: Keccak, ABI, EIP-712 / SafeTx, MultiSend, UR / CBOR, risk rules, WebAuthn signature encoding. **No networking code.** |
| `apps/signer/` | iPhone signer (offline, Secure Enclave P-256). Build guide: [BUILDING.md](../apps/signer/BUILDING.md) |
| `apps/coordinator/` | Mac desktop app (still called Coordinator in code) |
| `contracts/` | Foundry tests, gas benchmarks and deployment scripts against Safe and safe-modules. Safe contracts are used as-is, never modified |
| `testvectors/` | Shared test vectors from viem, Foundry, Blockchain Commons and Keystone |

## Specs

- [webauthn-signature.md](webauthn-signature.md): how the Secure Enclave key produces a signature Safe's WebAuthn signer accepts, with gas numbers and canonical deployments
- [ur-types.md](ur-types.md): the QR protocol (UR, EIP-4527, and our custom types)
- [decoding.md](decoding.md), [rules.md](rules.md): how the signer decodes transactions and judges risk

## Decisions and evidence

- [evidence.md](evidence.md): verified facts and on-chain evidence
- [demo.md](demo.md): the demo script, including the attack scenarios

## Research and future work

- [future-work.md](future-work.md): YubiKey, Pixel, on-chain Guard, gas refunds, ERC-4337, post-quantum owners, custom tokens
- [guard-design.md](guard-design.md): on-chain Guard design (not built)
