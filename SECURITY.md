# Security

UniPass Inkan is a proof of concept. It has had no external security audit, and there is no bug bounty or response-time commitment. Do not put real funds behind it.

The signer takes all its randomness from the Secure Enclave: the signing key and the ECDSA nonce of every signature are generated inside it, and the app can neither check them nor add its own entropy. Signatures end up public on chain, so a weak nonce would expose the key. We rely on Apple here and cannot verify it; this is one reason the iPhone is meant to be one owner of a multisig.

## Reporting a vulnerability

Please do not report security problems in public issues. Use GitHub's private reporting instead: [Report a vulnerability](https://github.com/zhixianio/unipass-inkan/security/advisories/new).

Useful to include:

- which part is affected (iPhone signer, desktop app, `core/`, contracts or scripts) and the commit you tested;
- what an attacker needs: control of the desktop app or its network, a crafted QR code, physical access to the phone, and so on;
- steps to reproduce, ideally a failing test or a Sepolia transaction.

## What counts

The signer is designed on the assumption that the desktop app, its network and its RPC nodes can all be malicious. Examples of what we want to hear about:

- the signer signing something other than what its review screen shows, or signing without the user's Face ID;
- a transaction the risk rules should flag or refuse getting through as green or yellow;
- the signer reaching the network, or signing while the phone is online;
- the desktop app's submitter account signing anything outside its allow-list;
- a pairing, Safe registration or signature that should be refused but is accepted.

Out of scope: bugs that need a jailbroken phone, a compromised Mac that builds and installs the signer (see [apps/signer/BUILDING.md](apps/signer/BUILDING.md)), or flaws in iOS, the Secure Enclave or Safe's own contracts. Reports about Safe's contracts belong to [Safe's bug bounty](https://docs.safe.global/advanced/smart-account-bug-bounty).
