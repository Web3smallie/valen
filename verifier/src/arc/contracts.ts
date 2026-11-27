import { createPublicClient, http, keccak256, numberToHex, type PublicClient } from 'viem';
import { deriveEvmAddress } from '../concordium/cis8.js';
import { EvidenceCollector } from '../evidence.js';
import type { CheckOutcome } from '../types.js';

/**
 * Arc read transport. viem is used ONLY as an RPC pipe: every returned
 * value is decoded and compared by hand-written code below. Read-only:
 * eth_call, eth_getCode, eth_getStorageAt, eth_getLogs, eth_chainId.
 */
export interface ArcReads {
  readonly endpoint: string;
  getChainId(): Promise<number>;
  getFinalizedBlockNumber(): Promise<bigint>;
  getCode(address: string, blockTag: 'finalized'): Promise<string>;
  call(to: string, data: string, blockTag: 'finalized'): Promise<string>;
  getStorageAt(address: string, slot: string, blockTag: 'finalized'): Promise<string>;
  getLogsByBlockRange(params: {
    readonly addresses: readonly string[];
    readonly topic0: string;
    readonly fromBlock: bigint;
    readonly toBlock: bigint;
  }): Promise<ReadonlyArray<{ address: string; topics: readonly string[]; blockNumber: bigint }>>;
}

export class LiveArcReads implements ArcReads {
  readonly endpoint: string;
  private readonly client: PublicClient;

  constructor(rpcUrl = 'https://rpc.testnet.arc.io', fetchFn?: typeof fetch) {
    this.endpoint = rpcUrl;
    this.client = createPublicClient({
      transport: fetchFn === undefined ? http(rpcUrl) : http(rpcUrl, { fetchFn }),
    });
  }

  async getChainId(): Promise<number> {
    return this.client.getChainId();
  }

  async getFinalizedBlockNumber(): Promise<bigint> {
    const block = await this.client.getBlock({ blockTag: 'finalized' });
    return block.number;
  }

  async getCode(address: string, _blockTag: 'finalized'): Promise<string> {
    // viem types Bytecode as hex; block pinning rides on the call below.
    const code = await this.client.getBytecode({
      address: address as `0x${string}`,
      blockTag: 'finalized',
    });
    return code ?? '0x';
  }

  async call(to: string, data: string, _blockTag: 'finalized'): Promise<string> {
    const out = await this.client.call({
      to: to as `0x${string}`,
      data: data as `0x${string}`,
      blockTag: 'finalized',
    });
    return out.data ?? '0x';
  }

  async getStorageAt(address: string, slot: string, _blockTag: 'finalized'): Promise<string> {
    const value = await this.client.getStorageAt({
      address: address as `0x${string}`,
      slot: slot as `0x${string}`,
      blockTag: 'finalized',
    });
    return value ?? '0x';
  }

  async getLogsByBlockRange(params: {
    readonly addresses: readonly string[];
    readonly topic0: string;
    readonly fromBlock: bigint;
    readonly toBlock: bigint;
  }): Promise<ReadonlyArray<{ address: string; topics: readonly string[]; blockNumber: bigint }>> {
    // Raw eth_getLogs: viem is only the pipe; topic filtering stays explicit.
    const logs = await this.client.request({
      method: 'eth_getLogs',
      params: [
        {
          address: params.addresses as `0x${string}`[],
          topics: [params.topic0 as `0x${string}`],
          fromBlock: numberToHex(params.fromBlock),
          toBlock: numberToHex(params.toBlock),
        },
      ],
    });
    return logs.map((entry) => ({
      address: entry.address,
      topics: [...entry.topics],
      blockNumber: BigInt(entry.blockNumber ?? '0x0'),
    }));
  }
}

/** Function selectors used by the checks (verified: cast sig + live calls). */
export const SELECTOR_OWNER = '0x8da5cb5b';
export const SELECTOR_UPGRADE_INTERFACE_VERSION = '0xad3cb1cc';

/** keccak256 of exact runtime bytes, compared against hash pins. */
export function keccakOfCode(codeHex: string): string {
  return keccak256(codeHex as `0x${string}`);
}

/** Decode a 32-byte ABI address word to lowercase 0x form. */
export function decodeAddressWord(wordHex: string): string {
  const clean = wordHex.startsWith('0x') ? wordHex.slice(2) : wordHex;
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) {
    throw new Error(`not a 32-byte word: ${wordHex.slice(0, 20)}`);
  }
  return `0x${clean.slice(24).toLowerCase()}`;
}

/** Decode an ABI-encoded string return value (offset, length, bytes). */
export function decodeStringReturn(returnHex: string): string {
  const clean = (returnHex.startsWith('0x') ? returnHex.slice(2) : returnHex).toLowerCase();
  if (!/^[0-9a-f]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new Error('return data is not hex');
  }
  const bytes = Buffer.from(clean, 'hex');
  if (bytes.length < 64) {
    throw new Error('string return too short for offset+length');
  }
  const offset = Number(BigInt(`0x${bytes.subarray(0, 32).toString('hex')}`));
  if (offset + 32 > bytes.length) {
    throw new Error('string offset out of range');
  }
  const length = Number(BigInt(`0x${bytes.subarray(offset, offset + 32).toString('hex')}`));
  if (offset + 32 + length > bytes.length) {
    throw new Error('string length out of range');
  }
  return bytes.subarray(offset + 32, offset + 32 + length).toString('utf8');
}

/** ERC-7201 Ownable slot (OZ v5): keccak(keccak("openzeppelin.storage.Ownable")-1) & ~0xff. */
export const OWNABLE_SLOT = '0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300';
/** EIP-1967 implementation slot. */
export const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

/** Chain-id gate. Runs before ANY contract read; a mismatch aborts the Arc phase. */
export async function checkChainId(
  arc: ArcReads,
  expectedChainId: number,
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector('arc-chain-id', 'eth_chainId', arc.endpoint);
  let chainId: number;
  try {
    chainId = await arc.getChainId();
  } catch (error) {
    collector.row({
      block: 'n/a',
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'chain id unreadable',
      verdict: 'INCONCLUSIVE',
    });
    return collector.finish();
  }
  collector.row({
    block: 'n/a',
    raw: `chainId=${chainId}`,
    derived: `expected=${expectedChainId}`,
    verdict: chainId === expectedChainId ? 'PASS' : 'FAIL',
  });
  return collector.finish();
}

/**
 * Per-contract checks (a) code hash, (b) owner() + Ownable slot, (c) version
 * string, (e) owner EOA. Slot sub-checks go INCONCLUSIVE when the control
 * read did not establish TRUSTED_FOR_SLOTS; everything else evaluates.
 */
export async function checkContractBasics(
  arc: ArcReads,
  pin: ArcContractPin,
  pins: ArcPinsFile,
  finalizedBlock: string,
  controlTrusted: boolean,
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector(`arc-${pin.name}`, 'Arc RPC reads', arc.endpoint);
  const failRow = (raw: string, detail: string): CheckOutcome => {
    collector.row({ block: finalizedBlock, raw, derived: detail, verdict: 'FAIL' });
    return collector.finish();
  };
  const inconclusiveRow = (raw: string, detail: string): CheckOutcome => {
    collector.row({ block: finalizedBlock, raw, derived: detail, verdict: 'INCONCLUSIVE' });
    return collector.finish();
  };
  let code: string;
  try {
    code = await arc.getCode(pin.proxy, 'finalized');
  } catch (error) {
    return inconclusiveRow(
      error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      'proxy code unreadable',
    );
  }
  if (code === '0x' || code.length <= 2) {
    return failRow(`code at ${pin.proxy}: empty`, 'proxy has no deployed bytecode');
  }
  let codeHash: string;
  try {
    codeHash = keccakOfCode(code);
  } catch {
    return failRow(`code at ${pin.proxy}: ${code.slice(0, 40)}...`, 'code is not valid hex');
  }
  if (codeHash.toLowerCase() !== pins.proxyCodeHash.toLowerCase()) {
    return failRow(`proxy code keccak ${codeHash}`, `expected pinned ${pins.proxyCodeHash}`);
  }
  const byteLength = code.length / 2 - 1;
  if (byteLength !== pins.proxyCodeBytes) {
    collector.row({
      block: finalizedBlock,
      raw: `proxy code ${byteLength} bytes`,
      derived: `pinned ${pins.proxyCodeBytes} bytes`,
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  collector.row({
    block: finalizedBlock,
    raw: `proxy code ${byteLength} bytes, keccak ${codeHash}`,
    derived: 'matches pinned proxy hash and size',
    verdict: 'PASS',
  });
  const expectedOwner = pins.owner.toLowerCase();
  let ownerReturn: string;
  try {
    ownerReturn = await arc.call(pin.proxy, SELECTOR_OWNER, 'finalized');
  } catch (error) {
    return inconclusiveRow(
      error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      'owner() unreadable',
    );
  }
  let owner: string;
  try {
    owner = decodeAddressWord(ownerReturn);
  } catch {
    return failRow(`owner() returned: ${ownerReturn.slice(0, 66)}`, 'not a 32-byte address word');
  }
  if (owner !== expectedOwner) {
    return failRow(`owner() = ${owner}`, `expected ${expectedOwner}`);
  }
  collector.row({
    block: finalizedBlock,
    raw: `owner() = ${owner}`,
    derived: `matches expected ${expectedOwner}`,
    verdict: 'PASS',
  });
  try {
    const slotWord = await arc.getStorageAt(pin.proxy, OWNABLE_SLOT, 'finalized');
    if (!controlTrusted) {
      collector.row({
        block: finalizedBlock,
        raw: `Ownable slot: ${slotWord.slice(0, 66)}`,
        derived: 'control read untrusted: slot evidence recorded but not decisive',
        verdict: 'INCONCLUSIVE',
      });
    } else {
      const slotOk = slotWord.toLowerCase() === `0x${'0'.repeat(24)}${owner.slice(2)}`;
      collector.row({
        block: finalizedBlock,
        raw: `Ownable slot: ${slotWord.slice(0, 66)}`,
        derived: slotOk ? 'equals owner() word' : 'DIFFERS from owner() word',
        verdict: slotOk ? 'PASS' : 'FAIL',
      });
      if (!slotOk) {
        return collector.finish();
      }
    }
  } catch (error) {
    collector.row({
      block: finalizedBlock,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'Ownable slot unreadable',
      verdict: 'INCONCLUSIVE',
    });
  }
  let versionReturn: string;
  try {
    versionReturn = await arc.call(pin.proxy, SELECTOR_UPGRADE_INTERFACE_VERSION, 'finalized');
  } catch (error) {
    return inconclusiveRow(
      error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      'UPGRADE_INTERFACE_VERSION() unreadable',
    );
  }
  let version: string;
  try {
    version = decodeStringReturn(versionReturn);
  } catch {
    return failRow(`version return: ${versionReturn.slice(0, 66)}`, 'not an ABI string');
  }
  if (version !== '5.0.0') {
    return failRow(`UPGRADE_INTERFACE_VERSION() = ${JSON.stringify(version)}`, 'expected "5.0.0"');
  }
  collector.row({
    block: finalizedBlock,
    raw: 'UPGRADE_INTERFACE_VERSION() = "5.0.0"',
    derived: 'UUPS v5 marker confirmed through the proxy',
    verdict: 'PASS',
  });
  let ownerCode: string;
  try {
    ownerCode = await arc.getCode(pins.owner, 'finalized');
  } catch (error) {
    return inconclusiveRow(
      error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      'owner code unreadable',
    );
  }
  if (ownerCode !== '0x') {
    return failRow(
      `code at owner ${pins.owner}: ${ownerCode.length / 2 - 1} bytes`,
      'owner is not an EOA',
    );
  }
  collector.row({
    block: finalizedBlock,
    raw: `code at owner ${pins.owner}: empty`,
    derived: 'owner is an EOA',
    verdict: 'PASS',
  });
  return collector.finish();
}

/**
 * Card cross-check: the card's contract inventory must equal the pins list
 * exactly (both directions), and the card's owner must equal the
 * Concordium-derived address.
 */
export function checkCardContracts(
  cardJson: unknown,
  pins: ArcPinsFile,
  derivedArcAddress: string,
): CheckOutcome {
  const collector = new EvidenceCollector('arc-card-crosscheck', 'card JSON vs pins', 'card + pins file');
  const failRow = (raw: string, detail: string): CheckOutcome => {
    collector.row({ block: 'n/a', raw, derived: detail, verdict: 'FAIL' });
    return collector.finish();
  };
  const card = cardJson as Record<string, unknown> | null;
  const xvalen = (card !== null && typeof card === 'object' ? card['x-valen'] : null) as Record<
    string,
    unknown
  > | null;
  const contracts = xvalen?.['contracts'] as Record<string, unknown> | null;
  if (!contracts || typeof contracts !== 'object' || Array.isArray(contracts)) {
    return failRow('card x-valen.contracts missing or malformed', 'cannot compare inventories');
  }
  const cardEntries = Object.entries(contracts);
  if (cardEntries.length !== pins.contracts.length) {
    return failRow(
      `card lists ${cardEntries.length} contracts, pins list ${pins.contracts.length}`,
      'inventories must match exactly',
    );
  }
  for (const pin of pins.contracts) {
    const match = cardEntries.find(([name]) => name.toLowerCase() === pin.name.toLowerCase());
    if (!match || typeof match[1] !== 'string') {
      return failRow(`pin contract ${pin.name} (${pin.proxy})`, 'absent from card inventory');
    }
    if ((match[1] as string).toLowerCase() !== pin.proxy.toLowerCase()) {
      return failRow(
        `card ${match[0]} = ${match[1]}`,
        `pins ${pin.name} = ${pin.proxy}: address mismatch`,
      );
    }
  }
  collector.row({
    block: 'n/a',
    raw: `${cardEntries.length} card entries, ${pins.contracts.length} pins`,
    derived: 'names and addresses match both directions',
    verdict: 'PASS',
  });
  const badge = (
    (card?.['capabilities'] as Record<string, unknown> | undefined)?.['extensions'] as
      | Array<Record<string, unknown>>
      | undefined
  )?.find((entry) => entry['uri'] === 'https://docs.concordium.com/a2a-extensions/concordium-badge/v1');
  const params = badge?.['params'] as Record<string, unknown> | undefined;
  const extref = params?.['externalReference'] as Record<string, unknown> | undefined;
  const identifier = extref?.['identifier'];
  const publicKey = extref?.['publicKey'];
  let cardOwner: string | null = null;
  if (typeof identifier === 'string') {
    cardOwner = identifier;
  } else if (typeof publicKey === 'string') {
    try {
      cardOwner = deriveEvmAddress(publicKey);
    } catch {
      return failRow(`card badge publicKey: ${publicKey.slice(0, 20)}...`, 'not a derivable key');
    }
  }
  if (cardOwner === null) {
    return failRow('card badge carries neither identifier nor publicKey', 'no card owner to compare');
  }
  const ownerOk = cardOwner.toLowerCase() === derivedArcAddress.toLowerCase();
  collector.row({
    block: 'n/a',
    raw: `card owner ref: ${cardOwner.slice(0, 66)}`,
    derived: `chain-derived ${derivedArcAddress} -> ${ownerOk ? 'MATCH' : 'MISMATCH'}`,
    verdict: ownerOk ? 'PASS' : 'FAIL',
  });
  return collector.finish();
}

export interface ArcContractPin {
  readonly name: string;
  readonly proxy: string;
  readonly implementation: string;
  readonly implementationCodeHash: string;
}

export interface ArcPinsFile {
  readonly chainId: number;
  readonly owner: string;
  readonly proxyCodeHash: string;
  readonly proxyCodeBytes: number;
  readonly contracts: ReadonlyArray<ArcContractPin>;
  readonly scan: {
    readonly lastVerifiedBlock: number;
    readonly upgradedTopic0: string;
    readonly maxChunkBlocks: number;
  };
}

/** Load and structurally validate a pins file. Unknown shape is FAIL, never defaulted. */
export function loadArcPinsFile(jsonText: string): ArcPinsFile {
  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonText) as unknown;
  } catch {
    throw new Error('pins file is not valid JSON');
  }
  const root = parsed as Record<string, unknown>;
  const hex = (value: unknown): value is string =>
    typeof value === 'string' && /^0x[0-9a-fA-F]+$/.test(value);
  const contracts = root['contracts'];
  if (!Array.isArray(contracts)) {
    throw new Error('pins file: contracts is not an array');
  }
  for (const entry of contracts) {
    const record = entry as Record<string, unknown>;
    if (
      typeof record['name'] !== 'string' ||
      !hex(record['proxy']) ||
      !hex(record['implementation']) ||
      !hex(record['implementationCodeHash'])
    ) {
      throw new Error(`pins file: malformed contract entry ${JSON.stringify(entry).slice(0, 80)}`);
    }
  }
  const scan = root['scan'] as Record<string, unknown> | undefined;
  if (
    typeof root['chainId'] !== 'number' ||
    !hex(root['owner']) ||
    !hex(root['proxyCodeHash']) ||
    typeof root['proxyCodeBytes'] !== 'number' ||
    !scan ||
    typeof scan['lastVerifiedBlock'] !== 'number' ||
    !hex(scan['upgradedTopic0']) ||
    typeof scan['maxChunkBlocks'] !== 'number'
  ) {
    throw new Error('pins file: missing or malformed top-level fields');
  }
  return {
    chainId: root['chainId'],
    owner: root['owner'],
    proxyCodeHash: root['proxyCodeHash'],
    proxyCodeBytes: root['proxyCodeBytes'],
    contracts: contracts.map((entry) => {
      const record = entry as Record<string, unknown>;
      return {
        name: record['name'] as string,
        proxy: record['proxy'] as string,
        implementation: record['implementation'] as string,
        implementationCodeHash: record['implementationCodeHash'] as string,
      };
    }),
    scan: {
      lastVerifiedBlock: scan['lastVerifiedBlock'],
      upgradedTopic0: scan['upgradedTopic0'],
      maxChunkBlocks: scan['maxChunkBlocks'],
    },
  };
}
