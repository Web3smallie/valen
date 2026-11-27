# Source correspondence: deployed implementations vs commit abd4225

Date: 2026-11-27. Main checkout at `9098748` (master); reproduction built
from detached worktree of `abd42258f9dba3cc1be5907b675d42b3d1bd4f2c`
(`feat: EURC multi-asset collateral upgrade + RPC URL migration`).
Worktree removed after the run; main checkout unmodified.

Result: **all 11 deployed implementation bytecodes match a fresh
abd4225 build**, modulo the regions below. This is a **bytecode match
modulo metadata and immutables; not a full source verification**.

## Environment and exact commands

- `forge` 1.8.1 (no standalone solc; solc 0.8.36 via svm download).
- `git worktree add /tmp/valen-abd4225 abd4225`
- `git submodule update --init --recursive` (exit 0).
- `forge build --use solc:0.8.36` (exit 0; lint notes only).
- `foundry.toml` at that commit pins neither solc nor optimizer, so the
  above plus foundry defaults are the instructed settings. Build-info
  confirms `solc: 0.8.36`, `optimizer: {"enabled": false, "runs": 200}`.
- Live code: `cast code <implementation> --block finalized --rpc-url
  https://rpc.testnet.arc.io` for each address in
  `verifier/pins/arc-testnet.json`.
- Comparison masked only the normalized regions, then byte-compared.

## Per-contract results

| Contract | Live | Template | Normalized | Result |
|---|---|---|---|---|
| AgentRegistry | 8694 B | 8694 B | 149 B | MATCH |
| CreditRegistry | 8871 B | 8871 B | 149 B | MATCH |
| LoanRegistry | 24184 B | 24184 B | 149 B | MATCH |
| RevenueRouter | 12973 B | 12973 B | 149 B | MATCH |
| LoanVault | 11932 B | 11932 B | 149 B | MATCH |
| CollateralVault | 14550 B | 14550 B | 149 B | MATCH |
| UnderwriterPool | 10170 B | 10170 B | 149 B | MATCH |
| RecipientRegistry | 6766 B | 6766 B | 149 B | MATCH |
| ReservePool | 7338 B | 7338 B | 149 B | MATCH |
| LiquidityPool | 16394 B | 16394 B | 149 B | MATCH |
| ActivityAttester | 7074 B | 7074 B | 149 B | MATCH |

Normalized 149 B = 53 B metadata tail + 96 B immutables (3 x 32 B) in
every contract. Zero unexplained diff bytes anywhere.

## Normalized regions

1. **CBOR metadata tail, last 53 bytes** (`[len-53, len)`).
   Structure-validated on both sides before masking: starts `0xa2`,
   ends `0x0033`, contains `ipfs` and `solc` markers, version bytes
   `00 08 24` (0.8.36). It embeds an IPFS hash of metadata that
   differs between the original deploy build and any rebuild, so it
   can never match byte-for-byte; everything outside it matches.
2. **Immutable slots from build-info `immutableReferences`**, all AST
   id 42650, resolved via the embedded AST to **`__self` in OZ
   `UUPSUpgradeable.sol`**. Live values hold each implementation's own
   address; the template holds zeros (`__self = address(this)` is
   fixed at creation time). No other immutables are declared.

Immutable offsets (length 32 each):

| Contract | Offsets |
|---|---|
| AgentRegistry | 5076, 5161, 5603 |
| CreditRegistry | 4332, 4417, 4859 |
| LoanRegistry | 12277, 12362, 12804 |
| RevenueRouter | 5209, 5294, 5736 |
| LoanVault | 6770, 6855, 7297 |
| CollateralVault | 8707, 8792, 9234 |
| UnderwriterPool | 5472, 5557, 5999 |
| RecipientRegistry | 2451, 2536, 3113 |
| ReservePool | 3266, 3351, 3793 |
| LiquidityPool | 10655, 10740, 11182 |
| ActivityAttester | 2936, 3021, 3463 |

## Keccak confirmation

Keccak256 of the full live runtime code equals
`verifier/pins/arc-testnet.json` for all 11 (verified
programmatically during the run).

## What was NOT reproduced

- Proxy bytecode (out of scope; the task covered implementations).
- The pinned pre-`lastVerifiedBlock` (74164159) upgrade history
  (not re-verified in that run).
- A full source verification (this is a bytecode match modulo
  metadata and immutables, per contract, against one stated commit
  and toolchain — not an audit of the sources themselves).
