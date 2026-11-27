# Valen registration verifier (standalone)

Independently verifies Valen's Concordium service-agent registration without
trusting Valen's backend or Concordium's hosted badge resolver. Reads chain
state directly from a Concordium node; fetches the Agent Card over HTTPS.

## Independence

- Zero imports from `backend/src/*`. All parsing (badge, `agentOf`,
  `ownerOfKey`, CAIP strings) is hand-written in this package.
- `@concordium/web-sdk` is transport only (gRPC pipe); every returned byte
  is parsed here. `viem` is transport + keccak; `@noble/curves` decompresses
  compressed keys. No repo helper code is reused.
- Hosted `check-badge` is used for comparison only, never as a dependency.

## Layout

- `src/config.ts` — pinned trust anchors (contracts, badge, accounts, chain).
- `src/types.ts`, `src/evidence.ts`, `src/report.ts` — evidence rows and
  fail-closed verdict aggregation (any FAIL fails; any INCONCLUSIVE on a
  required check fails).
- `src/concordium/` — `badge.ts` (Base58Check+ULEB128+CAIP-19),
  `agentView.ts`, `cis8.ts` (wire formats + EVM derivation), `node.ts`
  (finalized-block reads).
- `src/card/fetch.ts` — strict fetch: exact on-chain URL, HTTPS, 40-hex
  commit segment, no query/fragment/redirect, 1 MiB cap, SHA-256 match.
- `src/arc/control.ts` — storage control-read helper only (no contract
  checks yet).
- `test/` — offline tests with stub transports plus live-recorded fixtures;
  `live.test.ts` runs the trial run when `VERIFIER_LIVE=1`.

## Run

```bash
npm install          # inside verifier/ only, exact pinned versions
npm run typecheck
npm test             # offline suite (live test skips without VERIFIER_LIVE=1)
VERIFIER_LIVE=1 npm test -- live   # read-only trial run against testnet
```

## Pinned-read rule

Every Concordium read pins to the last finalized block reported at run
start; the block height is recorded on every evidence row. A TOCTOU
re-read of `agent_of` closes each run: any byte-level change fails it.
