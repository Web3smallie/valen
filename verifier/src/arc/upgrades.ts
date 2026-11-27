import { EvidenceCollector } from '../evidence.js';
import type { CheckOutcome } from '../types.js';
import type { ArcPinsFile, ArcReads } from './contracts.js';

/** keccak256("Upgraded(address)") — independently computed, pinned here, cross-checked in tests. */
export const UPGRADED_TOPIC0 = '0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b';

export const ARC_LIMITATIONS: readonly string[] = [
  'Pinned implementations are the V3 abd4225 builds; V4 is prepared but not deployed.',
  'Pins must be updated after any upgrade is run.',
  'Testnet identity is not KYC or real-world identity assurance.',
  'owner() equality is not a contract audit and says nothing about safety.',
  'RPC data is trusted without proofs; reads pin to the finalized block and record it.',
  'The owner key can upgrade all 11 contracts (single-EOA UUPS authority).',
];

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface ScanInput {
  readonly fromBlock: bigint;
  readonly toBlock: bigint;
  readonly maxChunkBlocks: number;
}

function chunkRanges(input: ScanInput): Array<{ from: bigint; to: bigint }> {
  const size = BigInt(Math.max(1, input.maxChunkBlocks));
  const ranges: Array<{ from: bigint; to: bigint }> = [];
  let from = input.fromBlock;
  while (from <= input.toBlock) {
    const to = from + size - 1n > input.toBlock ? input.toBlock : from + size - 1n;
    ranges.push({ from, to });
    from = to + 1n;
  }
  return ranges;
}

/**
 * Bounded Upgraded-event scan (C4). Scans [lastVerifiedBlock+1, finalized]
 * for the Upgraded topic on the 11 proxies, in chunks, with backoff.
 * Zero events is PASS with the exact required wording; any in-range event
 * is FAIL (no expected entries exist); RPC failure after retries is
 * INCONCLUSIVE.
 */
export async function checkUpgradedScan(
  arc: ArcReads,
  pins: ArcPinsFile,
  finalizedBlockNumber: bigint,
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector('arc-upgrades-scan', 'eth_getLogs', arc.endpoint);
  if (pins.scan.upgradedTopic0.toLowerCase() !== UPGRADED_TOPIC0) {
    collector.row({
      block: `finalized #${finalizedBlockNumber.toString()}`,
      raw: `pins topic: ${pins.scan.upgradedTopic0}`,
      derived: `expected: ${UPGRADED_TOPIC0}`,
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const from = BigInt(pins.scan.lastVerifiedBlock) + 1n;
  const to = finalizedBlockNumber;
  if (from > to) {
    collector.row({
      block: `finalized #${to.toString()}`,
      raw: `range starts at ${from.toString()}, finalized is ${to.toString()}`,
      derived: 'nothing new to scan yet',
      verdict: 'PASS',
    });
    return collector.finish();
  }
  const ranges = chunkRanges({
    fromBlock: from,
    toBlock: to,
    maxChunkBlocks: pins.scan.maxChunkBlocks,
  });
  const addresses = pins.contracts.map((entry) => entry.proxy);
  for (const [index, range] of ranges.entries()) {
    let attempt = 0;
    let logs: ReadonlyArray<{ address: string; topics: readonly string[]; blockNumber: bigint }> | null = null;
    let lastError = '';
    while (attempt < 3) {
      try {
        logs = await arc.getLogsByBlockRange({
          addresses,
          topic0: UPGRADED_TOPIC0,
          fromBlock: range.from,
          toBlock: range.to,
        });
        break;
      } catch (error) {
        lastError = error instanceof Error ? error.message.slice(0, 120) : 'transport error';
        attempt += 1;
        if (attempt < 3) {
          await sleep(1000 * 2 ** (attempt - 1));
        }
      }
    }
    if (logs === null) {
      collector.row({
        block: `finalized #${to.toString()}`,
        raw: `chunk ${index + 1}/${ranges.length} [${range.from.toString()},${range.to.toString()}]: ${lastError}`,
        derived: 'log range unreadable after retries',
        verdict: 'INCONCLUSIVE',
      });
      return collector.finish();
    }
    for (const entry of logs) {
      const addressOk = addresses.some((pinned) => pinned.toLowerCase() === entry.address.toLowerCase());
      const topicOk = entry.topics.length > 0 && (entry.topics[0] as string).toLowerCase() === UPGRADED_TOPIC0;
      const blockOk = entry.blockNumber >= range.from && entry.blockNumber <= range.to;
      collector.row({
        block: `finalized #${to.toString()}`,
        raw: `event @${entry.blockNumber.toString()} ${entry.address} topics=${entry.topics.length}`,
        derived: `addressOk=${String(addressOk)} topicOk=${String(topicOk)} blockOk=${String(blockOk)}`,
        verdict: 'FAIL',
      });
      return collector.finish();
    }
  }
  collector.row({
    block: `finalized #${to.toString()}`,
    raw: `${ranges.length} chunk(s) over [${from.toString()},${to.toString()}]`,
    derived: `no Upgraded events from block ${from.toString()} to ${to.toString()}`,
    verdict: 'PASS',
  });
  return collector.finish();
}
