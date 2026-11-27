# Step 2 — Valen CIS-8 Cross-Chain Binding (Concordium Testnet)

Links Valen's designated Concordium account to the Arc Testnet EOA that
owns Valen's 11 lending contracts. Status: **complete and verified
live** — binding submitted, finalized, and confirmed Active on-chain.

## Bound identities

| Role | Value | How confirmed |
|---|---|---|
| Concordium account | `4JnNAPh8mrS2BF2wcaB9Cdp83JscgvXuboxoUnnxesv39kcrCR` | Designated service identity; standing read live (nonce 1, 20,000 CCD faucet-funded, 1 normal credential, IP 0, valid 202611–202711) |
| Account hex | `b376ffb2f41efa8a524ab6f6cf7b2f481c271d968ec21c4dd0a063647c516fea` | SDK base58 decode; matches live binding owner |
| Arc owner address | `0xB0E8Ba6aFe21371AD4001e611224FC200FD10144` | `owner()` read on all 11 contracts; matches manifest `deployer` |
| Arc owner pubkey | `04e6a2ba9…9852cab` (65-byte uncompressed at submission) | Derived from deployer key; re-derives to the owner address |
| CIS-8 contract | Testnet `<12801,0>` | Pinned in `backend/src/concordium/config.ts` |
| Namespace | `eip155:5042002` (Arc Testnet, chain id 5042002) | Required by this step; confirmed on-chain |
| Key type submitted | `secp256k1-uncompressed` | CIS-8 spec standard value; enforced for Valen inputs |
| Key type on-chain | `secp256k1-compressed` (normalized echo, see below) | Read live from the binding record |
| Proof scheme | `ethereum-personal-sign` | CIS-8 spec; confirmed on-chain |

Service-account history: `49BGJ…` was the Step 2 preparation
identity; the designation moved to `4JnN…` before submission, and the
live binding belongs to `4JnN…` only. Token 1405 (owned by `49BGJ…`)
was left untouched.

## Finalized transaction

- Hash: `209dc1376379c89c0adc7a99f9f6fdc55ea879f68f9bdf3411dca78a3efd5c38`
- Sender `4JnN…`, `registerExternalKey` on `<12801,0>`, Success,
  block 51273492 (2026-11-25T11:20:02Z), actual cost ~18.7 CCD.
- Explorer: `https://testnet.ccdscan.io/` (search the hash above).

## What CIS-8 binds

CIS-8 binds an **external key, not a smart contract**. The on-chain
record asserts: "Concordium account X controls secp256k1 public key
Y", proven by a signature from Y over the canonical message. The Arc
owner *address* never appears on Concordium; verifiers re-derive it
from the bound pubkey (`last20(keccak(x‖y))`) and compare it against
the owners reported by Valen's contracts. Registry metadata
(`external_address`) is registrant-asserted and is never trusted.

## Compressed-key normalization (deployed behavior)

The CIS-8 contract stores keys compressed and **echoes
`secp256k1-compressed` (33-byte `02`/`03` form) even when the
registered key id was `secp256k1-uncompressed`**. Valen's binding
demonstrates this: submitted as 65-byte `04e6a2…`, stored and echoed
as 33-byte `03e6a2…` with the identical x-coordinate. Key identity is
therefore the x-coordinate, never the encoding label — verification
compares `secp256k1X()` on both sides and re-derives the EVM address
from the echoed key.

## Wrapper fix (post-submission)

The first live verification fail-closed with
`CIS8_KEYTYPE_REJECTED`: `verifyValenBinding` pinned its allowlist to
uncompressed-only and rejected the normalized echo before reaching
the x-coordinate comparison. Fixed by accepting the normalized
compressed echo on READ while keeping Valen's submitted key id
uncompressed-only (`buildValenBindingKeyId` unchanged and still
rejecting compressed input). No other check was weakened: namespace
pin, scheme allowlist, owner match, re-derivation, and Active gate
all intact. Regression test
(`ownerOfKey-valen-5042002.json`, recorded live with the tx hash
above) verifies end-to-end against the real compressed echo. Full
backend suite green; live verification green after the fix.

## Creation procedure (as executed)

1. Approved the binding: account, key, and namespace as tabled.
2. Ran the read-only prep script (explicit identity inputs, never
   fixture defaults) for canonical bytes and the EIP-191 digest.
3. Signed the digest with the Arc owner key (`personal_sign`; a
   message signature, independently recovery-verified to the owner).
4. Submitted `registerExternalKey` from `4JnN…` via Concordium Client
   with the officially built payload (unsigned JSON reviewed first).
5. Verified (see below).

## Independent verification

Any party can verify without trusting Valen:

1. `ownerOfKey(eip155:5042002, secp256k1-uncompressed, <pubkey>)`
   on `<12801,0>` → record must be Active, owner `b376…fea`,
   scheme `ethereum-personal-sign` (echo arrives compressed; compare
   x-coordinates, not encodings).
2. Re-derive `last20(keccak(pubkey))` → must equal the Arc owner.
3. Call `owner()` on all 11 manifest contracts → all must equal it.
4. Scripted: `prepareValenBinding.ts --account … --pubkey … --verify`
   runs all of the above and fails closed on any deviation.

## Limitations

- **EOA assumption.** The binding proves control of one secp256k1
  key. If Valen moves to multisig/Safe ownership, this binding no
  longer captures "the contracts are controlled by this party" and a
  different accountability mechanism is required.
- **Displacement.** Anyone with the owner key can re-register the
  binding under another Concordium account, displacing Valen's (and
  vice versa). Verification must therefore always read live state —
  which `verifyValenBinding` does.
- **No expiry.** The canonical message carries no nonce/expiry by
  design; replay protection comes from the Concordium transaction.
- Historical deployment transactions are no longer served by the Arc
  RPC (pruned), so pubkey recovery from chain history was unavailable;
  the pubkey stands on local derivation plus re-derivation to the
  11×-confirmed owner.

## Code map

- `backend/src/concordium/valenBinding.ts` — key id, canonical bytes,
  personal-sign digest, binding + Arc-owner verification (no signing).
- `backend/src/concordium/cis8.ts` — shared CIS-8 verify with scheme
  allowlist enforcement.
- `backend/src/prepareValenBinding.ts` — read-only prep/verify script.
- `backend/src/concordium/valenBinding.test.ts` — 19 tests incl. live
  compressed-echo regression; F1 fixture used only as negative input,
  unmodified.
- `backend/src/concordium/testdata/ownerOfKey-valen-5042002.json` —
  live-recorded Valen binding (compressed echo + submitting tx hash).
