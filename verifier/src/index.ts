import { PINNED, SANITY, type PinnedInputs } from './config.js';
import { EvidenceCollector } from './evidence.js';
import { aggregate, printReport, reportToJson } from './report.js';
import type { CheckOutcome, Verdict, VerifierReport, VerifierReportJSON } from './types.js';
import {
  accountHexToBase58,
  decodeBadgeShortForm,
  splitBadgeCaip19,
  type DecodedBadge,
} from './concordium/badge.js';
import {
  encodeExternalReferenceParam,
  encodeTokenIdParam,
  parseAgentOfResponse,
  type AgentRecord,
} from './concordium/agentView.js';
import {
  deriveEvmAddress,
  parseOwnerOfKeyResponse,
  type Cis8KeyId,
} from './concordium/cis8.js';
import type { ConcordiumTransports } from './concordium/node.js';
import { CardFetchError, fetchCard, type FetchFunction } from './card/fetch.js';
import {
  checkCardContracts,
  checkChainId,
  checkContractBasics,
  loadArcPinsFile,
  OWNABLE_SLOT,
  SELECTOR_OWNER,
  type ArcPinsFile,
  type ArcReads,
} from './arc/contracts.js';
import { checkProxyLinkage } from './arc/proxies.js';
import { ARC_LIMITATIONS, checkUpgradedScan } from './arc/upgrades.js';
import { runControlRead, type ArcStorageTransport } from './arc/control.js';

export * from './config.js';
export * from './types.js';
export * from './evidence.js';
export * from './report.js';
export * from './concordium/badge.js';
export * from './concordium/agentView.js';
export * from './concordium/cis8.js';
export * from './concordium/node.js';
export * from './card/fetch.js';
export * from './arc/control.js';
export * from './arc/contracts.js';
export * from './arc/proxies.js';
export * from './arc/upgrades.js';

export interface RunDependencies {
  readonly node: ConcordiumTransports;
  readonly fetchFn?: FetchFunction;
}

interface AgentCardShape {
  readonly badge: Record<string, unknown>;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

/** Extract the Concordium badge extension params from a parsed card. Throws CardStructureError on any deviation. */
export class CardStructureError extends Error {}

const BADGE_EXTENSION_URI = 'https://docs.concordium.com/a2a-extensions/concordium-badge/v1';

function extractBadgeParams(cardJson: unknown): Record<string, unknown> {
  const card = asRecord(cardJson);
  const capabilities = card ? asRecord(card['capabilities']) : null;
  const extensions = capabilities ? capabilities['extensions'] : null;
  if (!Array.isArray(extensions)) {
    throw new CardStructureError('card.capabilities.extensions is not an array');
  }
  for (const entry of extensions) {
    const ext = asRecord(entry);
    if (ext?.['uri'] === BADGE_EXTENSION_URI) {
      const params = asRecord(ext['params']);
      if (!params) {
        throw new CardStructureError('badge extension has no params object');
      }
      return params;
    }
  }
  throw new CardStructureError('no Concordium badge extension found');
}

function shortVerdict(ok: boolean): Verdict {
  return ok ? 'PASS' : 'FAIL';
}

async function checkBadge(
  deps: RunDependencies,
  pins: PinnedInputs,
): Promise<{ outcome: CheckOutcome; decoded: DecodedBadge | null }> {
  const collector = new EvidenceCollector('1-badge', 'local-parse', 'none (offline)');
  let decoded: DecodedBadge | null = null;
  try {
    const input = pins.badgeCaip19;
    let shortForm: string;
    if (input.startsWith('ccd:')) {
      const parts = splitBadgeCaip19(input);
      const expectedPrefix = pins.concordiumGenesisHashHex.slice(0, 32).toLowerCase();
      collector.row({
        block: 'n/a',
        raw: `genesis prefix: ${parts.genesisPrefix}`,
        derived: `expected prefix: ${expectedPrefix}`,
        verdict: shortVerdict(parts.genesisPrefix.toLowerCase() === expectedPrefix),
      });
      if (parts.genesisPrefix.toLowerCase() !== expectedPrefix) {
        return { outcome: collector.finish(), decoded: null };
      }
      shortForm = parts.shortForm;
    } else {
      shortForm = input;
      collector.note('short-form input: no genesis prefix to check');
    }
    decoded = decodeBadgeShortForm(shortForm);
    const contractOk =
      decoded.contractIndex === pins.cis8004Contract.index &&
      decoded.contractSubindex === pins.cis8004Contract.subindex;
    collector.row({
      block: 'n/a',
      raw: `badge: ${shortForm}`,
      derived: `contract ${decoded.contractIndex.toString()},${decoded.contractSubindex.toString()} token ${decoded.tokenId.toString()}`,
      verdict: shortVerdict(contractOk),
    });
    if (!contractOk) {
      return { outcome: collector.finish(), decoded: null };
    }
    const tokenOk = decoded.tokenId === pins.expectedTokenId;
    collector.row({
      block: 'n/a',
      raw: `token ${decoded.tokenId.toString()}`,
      derived: `expected ${pins.expectedTokenId.toString()}`,
      verdict: shortVerdict(tokenOk),
    });
    if (!tokenOk) {
      return { outcome: collector.finish(), decoded: null };
    }
  } catch (error) {
    collector.row({
      block: 'n/a',
      raw: pins.badgeCaip19,
      derived: error instanceof Error ? error.message.slice(0, 160) : 'parse error',
      verdict: 'FAIL',
    });
    return { outcome: collector.finish(), decoded: null };
  }
  return { outcome: collector.finish(), decoded };
}

interface AgentData {
  readonly record: AgentRecord;
  readonly rawHex: string;
  readonly block: string;
}

async function checkAgentOf(
  deps: RunDependencies,
  pins: PinnedInputs,
  tokenId: bigint,
  blockHash: string,
  blockLabel: string,
): Promise<{ outcome: CheckOutcome; data: AgentData | null }> {
  const collector = new EvidenceCollector('2-agentOf', 'CIS-8004.agentOf', deps.node.endpoint);
  let rawHex: string;
  try {
    rawHex = await deps.node.invokeAgentOf(
      { index: pins.cis8004Contract.index, subindex: pins.cis8004Contract.subindex },
      tokenId,
      blockHash,
    );
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'no bytes received',
      verdict: 'INCONCLUSIVE',
    });
    return { outcome: collector.finish(), data: null };
  }
  let parsed;
  try {
    parsed = parseAgentOfResponse(rawHex);
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: rawHex.slice(0, 200),
      derived: error instanceof Error ? error.message.slice(0, 160) : 'parse error',
      verdict: 'FAIL',
    });
    return { outcome: collector.finish(), data: null };
  }
  if (!parsed.found) {
    collector.row({
      block: blockLabel,
      raw: rawHex,
      derived: 'agent absent on chain',
      verdict: 'FAIL',
    });
    return { outcome: collector.finish(), data: null };
  }
  if (parsed.tokenId !== tokenId) {
    collector.row({
      block: blockLabel,
      raw: `echoed token ${parsed.tokenId.toString()}`,
      derived: `queried ${tokenId.toString()}`,
      verdict: 'FAIL',
    });
    return { outcome: collector.finish(), data: null };
  }
  collector.row({
    block: blockLabel,
    raw: `status=${parsed.status} owner=${parsed.ownerHex}`,
    derived: `uri=${parsed.agentUri ?? 'MISSING'} hash=${parsed.metadataHashHex ?? 'MISSING'}`,
    verdict: shortVerdict(parsed.status === 'Active' && parsed.agentUri !== null && parsed.metadataHashHex !== null),
  });
  if (parsed.status !== 'Active' || parsed.agentUri === null || parsed.metadataHashHex === null) {
    return { outcome: collector.finish(), data: null };
  }
  collector.note(parsed.trailingNote);
  if (!parsed.metadataHashHex.toLowerCase().startsWith(SANITY.metadataHashPrefix)) {
    collector.note(
      `sanity: on-chain hash does not start with ${SANITY.metadataHashPrefix} (reported only, not a verdict input)`,
    );
  }
  collector.row({
    block: blockLabel,
    raw: `full return value (${rawHex.length / 2} bytes)`,
    derived: rawHex,
    verdict: 'PASS',
  });
  return {
    outcome: collector.finish(),
    data: { record: parsed, rawHex, block: blockLabel },
  };
}

interface CardData {
  readonly url: string;
  readonly sha256Hex: string;
  readonly byteLength: number;
  readonly json: unknown;
}

async function checkCard(
  deps: RunDependencies,
  agentUri: string,
  expectedHashHex: string,
): Promise<{ outcome: CheckOutcome; data: CardData | null }> {
  const collector = new EvidenceCollector('3-card', 'agent_uri HTTPS fetch', agentUri);
  let fetched;
  try {
    fetched = await fetchCard(agentUri, deps.fetchFn);
  } catch (error) {
    collector.row({
      block: 'n/a (web)',
      raw: error instanceof CardFetchError ? error.message.slice(0, 160) : 'fetch error',
      derived: 'no card bytes obtained',
      verdict: 'INCONCLUSIVE',
    });
    return { outcome: collector.finish(), data: null };
  }
  const match = fetched.sha256Hex.toLowerCase() === expectedHashHex.toLowerCase();
  collector.row({
    block: 'n/a (web)',
    raw: `http ${fetched.status}, ${fetched.bytes.length} bytes, sha256 ${fetched.sha256Hex}`,
    derived: `on-chain hash ${expectedHashHex} -> ${match ? 'MATCH' : 'MISMATCH'}`,
    verdict: shortVerdict(match),
  });
  if (fetched.bytes.length !== SANITY.cardByteLength) {
    collector.note(
      `sanity: card is ${fetched.bytes.length} bytes, expected ${SANITY.cardByteLength} (reported only)`,
    );
  }
  if (!match) {
    return { outcome: collector.finish(), data: null };
  }
  return {
    outcome: collector.finish(),
    data: { url: fetched.url, sha256Hex: fetched.sha256Hex, byteLength: fetched.bytes.length, json: fetched.json },
  };
}

async function checkBadgeBlock(
  deps: RunDependencies,
  pins: PinnedInputs,
  agent: AgentRecord,
  badgeShortForm: string,
  cardJson: unknown,
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector('4-badge-block', 'card JSON vs chain', 'card + chain record');
  let params: Record<string, unknown>;
  try {
    params = extractBadgeParams(cardJson);
  } catch (error) {
    collector.row({
      block: 'n/a',
      raw: error instanceof Error ? error.message : 'structure error',
      derived: 'badge block unreadable',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const genesisPrefix = pins.concordiumGenesisHashHex.slice(0, 32).toLowerCase();
  const expectedTokenAddress = `ccd:${genesisPrefix}/cis-2:${badgeShortForm}`;
  const tokenOk = params['tokenAddress'] === expectedTokenAddress;
  collector.row({
    block: 'n/a',
    raw: `card tokenAddress: ${String(params['tokenAddress']).slice(0, 90)}`,
    derived: `expected: ${expectedTokenAddress}`,
    verdict: shortVerdict(tokenOk),
  });
  let ownerBase58 = '';
  try {
    ownerBase58 = accountHexToBase58(agent.ownerHex);
  } catch {
    collector.row({
      block: 'n/a',
      raw: `on-chain owner hex: ${agent.ownerHex}`,
      derived: 'not valid account bytes',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const expectedOwnerCaip = `ccd:${genesisPrefix}:${ownerBase58}`;
  const cardOwner = asRecord(params['owner'])?.['account'];
  const ownerOk = cardOwner === expectedOwnerCaip;
  collector.row({
    block: 'n/a',
    raw: `card owner: ${String(cardOwner).slice(0, 90)}`,
    derived: `chain owner: ${expectedOwnerCaip}`,
    verdict: shortVerdict(ownerOk),
  });
  const contracts = asRecord(params['contracts']);
  const cis8004Ok =
    contracts?.['cis8004'] ===
    `ccd:${genesisPrefix}:${pins.cis8004Contract.index.toString()}.${pins.cis8004Contract.subindex.toString()}`;
  const cis8Ok =
    contracts?.['cis8'] ===
    `ccd:${genesisPrefix}:${pins.cis8Contract.index.toString()}.${pins.cis8Contract.subindex.toString()}`;
  collector.row({
    block: 'n/a',
    raw: `card contracts: ${JSON.stringify(params['contracts']).slice(0, 120)}`,
    derived: `pinned 8004+8 match: ${String(cis8004Ok && cis8Ok)}`,
    verdict: shortVerdict(cis8004Ok === true && cis8Ok === true),
  });
  const cardExt = asRecord(params['externalReference']);
  const chainExt = agent.externalReference;
  if (!cardExt || !chainExt) {
    collector.row({
      block: 'n/a',
      raw: `card extref present: ${String(!!cardExt)}, chain extref present: ${String(!!chainExt)}`,
      derived: 'both sides must carry the external reference',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const kindOk = cardExt['kind'] === 'Cis8';
  const nsOk = cardExt['namespace'] === chainExt.key.namespace;
  let keyOk = false;
  let keyDetail = '';
  const cardPubkey = asString(cardExt['publicKey']);
  const cardKeyType = asString(cardExt['keyType']);
  if (cardPubkey !== null) {
    keyOk = cardPubkey.toLowerCase() === chainExt.key.publicKeyHex.toLowerCase() && cardKeyType === chainExt.key.keyType;
    keyDetail = `card key ${cardPubkey.slice(0, 18)}... vs chain ${chainExt.key.publicKeyHex.slice(0, 18)}...`;
  } else {
    const identifier = asString(cardExt['identifier']);
    if (identifier !== null) {
      try {
        const derived = deriveEvmAddress(chainExt.key.publicKeyHex);
        keyOk = derived.toLowerCase() === identifier.toLowerCase();
        keyDetail = `legacy identifier ${identifier} vs derived ${derived}`;
      } catch {
        keyDetail = 'chain key not derivable';
        keyOk = false;
      }
    } else {
      keyDetail = 'card extref carries neither publicKey nor identifier';
    }
  }
  collector.row({
    block: 'n/a',
    raw: `kind/ns/key: ${String(kindOk)}/${String(nsOk)}; ${keyDetail.slice(0, 140)}`,
    derived: `chain key ${chainExt.key.namespace}/${chainExt.key.keyType}`,
    verdict: shortVerdict(kindOk && nsOk && keyOk),
  });
  return collector.finish();
}

async function checkCis8Binding(
  deps: RunDependencies,
  pins: PinnedInputs,
  agent: AgentRecord,
  cardJson: unknown,
  blockHash: string,
  blockLabel: string,
  outbox: { derivedArcAddress: string | null },
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector('5-cis8', 'CIS-8.ownerOfKey', deps.node.endpoint);
  const chainExt = agent.externalReference;
  if (!chainExt) {
    collector.row({
      block: blockLabel,
      raw: 'agent record carries no external reference',
      derived: 'nothing to resolve',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  if (
    chainExt.contractIndex !== pins.cis8Contract.index ||
    chainExt.contractSubindex !== pins.cis8Contract.subindex
  ) {
    collector.row({
      block: blockLabel,
      raw: `extref contract ${chainExt.contractIndex.toString()},${chainExt.contractSubindex.toString()}`,
      derived: `pinned ${pins.cis8Contract.index.toString()},${pins.cis8Contract.subindex.toString()}`,
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const key: Cis8KeyId = {
    namespace: chainExt.key.namespace,
    keyType: chainExt.key.keyType,
    publicKeyHex: chainExt.key.publicKeyHex,
  };
  let rawHex: string;
  try {
    rawHex = await deps.node.invokeOwnerOfKey(
      { index: pins.cis8Contract.index, subindex: pins.cis8Contract.subindex },
      key,
      blockHash,
    );
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'no bytes received',
      verdict: 'INCONCLUSIVE',
    });
    return collector.finish();
  }
  let parsed;
  try {
    parsed = parseOwnerOfKeyResponse(rawHex);
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: rawHex.slice(0, 200),
      derived: error instanceof Error ? error.message.slice(0, 160) : 'parse error',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  if (!parsed.found) {
    collector.row({
      block: blockLabel,
      raw: rawHex,
      derived: 'no binding for this key',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  if (parsed.status !== 'Active') {
    collector.row({
      block: blockLabel,
      raw: `status=${parsed.status}`,
      derived: 'binding must be Active',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const ownerOk = parsed.ownerHex.toLowerCase() === agent.ownerHex.toLowerCase();
  collector.row({
    block: blockLabel,
    raw: `binding owner=${parsed.ownerHex} scheme=${parsed.proofScheme}`,
    derived: `agent owner=${agent.ownerHex} -> ${ownerOk ? 'MATCH' : 'MISMATCH'}`,
    verdict: shortVerdict(ownerOk),
  });
  if (!ownerOk) {
    return collector.finish();
  }
  // Bidirectional: the registry must resolve this key back to the same token.
  let reverseRaw: string;
  try {
    reverseRaw = await deps.node.invokeAgentByExternalReference(
      { index: pins.cis8004Contract.index, subindex: pins.cis8004Contract.subindex },
      encodeExternalReferenceParam({
        contractIndex: chainExt.contractIndex,
        contractSubindex: chainExt.contractSubindex,
        key,
      }),
      blockHash,
    );
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'reverse lookup unavailable',
      verdict: 'INCONCLUSIVE',
    });
    return collector.finish();
  }
  try {
    const reverse = parseAgentOfResponse(reverseRaw);
    const reverseOk = reverse.found && reverse.tokenId === agent.tokenId;
    collector.row({
      block: blockLabel,
      raw: reverse.found ? `reverse token=${reverse.tokenId.toString()}` : 'reverse lookup empty',
      derived: `expected token=${agent.tokenId.toString()}`,
      verdict: shortVerdict(reverseOk),
    });
    if (!reverseOk) {
      return collector.finish();
    }
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'parse error',
      derived: 'reverse record unreadable',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  // EVM address: derived from the chain key, compared to card + pinned expectation.
  let derived: string;
  try {
    derived = deriveEvmAddress(chainExt.key.publicKeyHex);
  } catch (error) {
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'derivation error',
      derived: 'address underivable',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  let cardAddress: string | null = null;
  try {
    const params = extractBadgeParams(cardJson);
    const cardExt = asRecord(params['externalReference']);
    const identifier = cardExt ? asString(cardExt['identifier']) : null;
    const cardPubkey = cardExt ? asString(cardExt['publicKey']) : null;
    if (identifier !== null) {
      cardAddress = identifier;
    } else if (cardPubkey !== null) {
      cardAddress = deriveEvmAddress(cardPubkey);
    }
  } catch {
    cardAddress = null;
  }
  const cardOk = cardAddress !== null && cardAddress.toLowerCase() === derived.toLowerCase();
  const pinOk = derived.toLowerCase() === pins.expectedArcOwner.toLowerCase();
  outbox.derivedArcAddress = derived;
  collector.row({
    block: blockLabel,
    raw: `derived=${derived} card=${cardAddress ?? ' unreadable'} pinned=${pins.expectedArcOwner}`,
    derived: `card match=${String(cardOk)} pin match=${String(pinOk)}`,
    verdict: shortVerdict(cardOk && pinOk),
  });
  return collector.finish();
}

/**
 * Run Concordium checks 1-5 plus the TOCTOU re-read. Fails closed: any
 * FAIL, or any INCONCLUSIVE on these required checks, fails the run.
 */
export interface ConcordiumArtifacts {
  readonly report: VerifierReport;
  /** Card JSON from the verified fetch, or null when checks 1-3 did not all pass. */
  readonly cardJson: unknown;
  /** EVM address derived from the chain CIS-8 key, or null when check 5 did not pass. */
  readonly derivedArcAddress: string | null;
}

export async function runConcordiumChecksWithArtifacts(
  deps: RunDependencies,
  pins: PinnedInputs = PINNED,
): Promise<ConcordiumArtifacts> {
  const fail = (cardJson: unknown = null, derivedArcAddress: string | null = null): ConcordiumArtifacts => ({
    report: aggregate(outcomes),
    cardJson,
    derivedArcAddress,
  });
  const outcomes: CheckOutcome[] = [];
  const badge = await checkBadge(deps, pins);
  outcomes.push(badge.outcome);
  if (!badge.decoded) {
    return fail();
  }
  let finalized: { hash: string; height: string };
  try {
    finalized = await deps.node.getFinalizedBlock();
  } catch (error) {
    const collector = new EvidenceCollector('2-agentOf', 'consensus status', deps.node.endpoint);
    collector.row({
      block: 'unknown',
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'cannot pin reads to a finalized block',
      verdict: 'INCONCLUSIVE',
    });
    outcomes.push(collector.finish());
    return fail();
  }
  const blockLabel = `finalized #${finalized.height}`;
  const agent = await checkAgentOf(deps, pins, badge.decoded.tokenId, finalized.hash, blockLabel);
  outcomes.push(agent.outcome);
  if (!agent.data) {
    return fail();
  }
  try {
    const ownerBase58 = accountHexToBase58(agent.data.record.ownerHex);
    if (ownerBase58 !== pins.expectedOwnerAccount) {
      const collector = new EvidenceCollector('2-agentOf', 'owner pin comparison', 'pins');
      collector.row({
        block: blockLabel,
        raw: `on-chain owner: ${ownerBase58}`,
        derived: `expected: ${pins.expectedOwnerAccount}`,
        verdict: 'FAIL',
      });
      outcomes.push(collector.finish());
    return fail();
    }
  } catch {
    const collector = new EvidenceCollector('2-agentOf', 'owner pin comparison', 'pins');
    collector.row({
      block: blockLabel,
      raw: `on-chain owner hex: ${agent.data.record.ownerHex}`,
      derived: 'not valid account bytes',
      verdict: 'FAIL',
    });
    outcomes.push(collector.finish());
    return fail();
  }
  const card = await checkCard(deps, agent.data.record.agentUri ?? '', agent.data.record.metadataHashHex ?? '');
  outcomes.push(card.outcome);
  if (!card.data) {
    return fail();
  }
  outcomes.push(await checkBadgeBlock(deps, pins, agent.data.record, badge.decoded.shortForm, card.data.json));
  const cis8Outbox = { derivedArcAddress: null as string | null };
  outcomes.push(
    await checkCis8Binding(
      deps,
      pins,
      agent.data.record,
      card.data.json,
      finalized.hash,
      blockLabel,
      cis8Outbox,
    ),
  );
  // TOCTOU: re-read agent_of; any byte-level change fails the run.
  try {
    const reread = await deps.node.invokeAgentOf(
      { index: pins.cis8004Contract.index, subindex: pins.cis8004Contract.subindex },
      badge.decoded.tokenId,
      finalized.hash,
    );
    const collector = new EvidenceCollector('6-toctou', 'CIS-8004.agentOf re-read', deps.node.endpoint);
    collector.row({
      block: blockLabel,
      raw: `first=${agent.data.rawHex.slice(0, 64)}... second=${reread.slice(0, 64)}...`,
      derived: reread === agent.data.rawHex ? 'identical' : 'CHANGED DURING RUN',
      verdict: shortVerdict(reread === agent.data.rawHex),
    });
    outcomes.push(collector.finish());
  } catch (error) {
    const collector = new EvidenceCollector('6-toctou', 'CIS-8004.agentOf re-read', deps.node.endpoint);
    collector.row({
      block: blockLabel,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 're-read unavailable',
      verdict: 'INCONCLUSIVE',
    });
    outcomes.push(collector.finish());
  }
  return fail(card.data.json, cis8Outbox.derivedArcAddress);
}

/** Report-only form of the Concordium run (phase-1 entry point, preserved). */
export async function runConcordiumChecks(
  deps: RunDependencies,
  pins: PinnedInputs = PINNED,
): Promise<VerifierReport> {
  return (await runConcordiumChecksWithArtifacts(deps, pins)).report;
}

export interface ArcArtifacts {
  readonly report: VerifierReport;
  readonly controlTrusted: boolean;
  readonly pins: ArcPinsFile | null;
}

/**
 * Run the Arc checks (C1-C5). Run order is a gate: pins load, owner-pin
 * agreement, chain id, finalized block, control read. No contract read
 * happens unless the chain gate passes on the pinned chain id.
 */
export async function runArcChecks(
  arc: ArcReads,
  pinsText: string,
  cardJson: unknown,
  derivedArcAddress: string,
): Promise<ArcArtifacts> {
  const outcomes: CheckOutcome[] = [];
  const finish = (controlTrusted: boolean, pins: ArcPinsFile | null): ArcArtifacts => ({
    report: aggregate(outcomes),
    controlTrusted,
    pins,
  });
  let pins: ArcPinsFile;
  try {
    pins = loadArcPinsFile(pinsText);
  } catch (error) {
    const collector = new EvidenceCollector('arc-pins', 'pins file parse', 'pins file');
    collector.row({
      block: 'n/a',
      raw: error instanceof Error ? error.message.slice(0, 160) : 'parse error',
      derived: 'pins unusable: Arc checks cannot run',
      verdict: 'FAIL',
    });
    outcomes.push(collector.finish());
    return finish(false, null);
  }
  {
    // B3: the pins owner must agree with the CIS-8-derived address.
    const collector = new EvidenceCollector('arc-owner-pin', 'derived address vs pins', 'pins file');
    const ownerOk = pins.owner.toLowerCase() === derivedArcAddress.toLowerCase();
    collector.row({
      block: 'n/a',
      raw: `pins owner: ${pins.owner}`,
      derived: `derived: ${derivedArcAddress} -> ${ownerOk ? 'MATCH' : 'MISMATCH'}`,
      verdict: ownerOk ? 'PASS' : 'FAIL',
    });
    outcomes.push(collector.finish());
    if (!ownerOk) {
      return finish(false, pins);
    }
  }
  const chain = await checkChainId(arc, pins.chainId);
  outcomes.push(chain);
  if (chain.verdict !== 'PASS') {
    return finish(false, pins);
  }
  let finalizedNumber: bigint;
  try {
    finalizedNumber = await arc.getFinalizedBlockNumber();
  } catch (error) {
    const collector = new EvidenceCollector('arc-finalized', 'eth_getBlock(finalized)', arc.endpoint);
    collector.row({
      block: 'unknown',
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'finalized block unreadable: contract reads cannot be pinned',
      verdict: 'INCONCLUSIVE',
    });
    outcomes.push(collector.finish());
    return finish(false, pins);
  }
  const finalizedLabel = `finalized #${finalizedNumber.toString()}`;
  let controlTrusted = false;
  {
    const collector = new EvidenceCollector('arc-control', 'Ownable-slot control read', arc.endpoint);
    const loanRegistry = pins.contracts.find((entry) => entry.name.toLowerCase() === 'loanregistry');
    if (!loanRegistry) {
      collector.row({
        block: finalizedLabel,
        raw: 'LoanRegistry absent from pins',
        derived: 'no control target: slot checks cannot be trusted',
        verdict: 'INCONCLUSIVE',
      });
    } else {
      const transport: ArcStorageTransport = {
        readStorage: (address, slot) => arc.getStorageAt(address, slot, 'finalized'),
        readOwnerCall: (address) => arc.call(address, SELECTOR_OWNER, 'finalized'),
      };
      try {
        const control = await runControlRead(transport, {
          address: loanRegistry.proxy,
          slot: OWNABLE_SLOT,
          blocks: ['finalized'],
        });
        controlTrusted = control.allMatch;
        for (const entry of control.entries) {
          collector.row({
            block: `${finalizedLabel} (${entry.block})`,
            raw: `observed=${entry.observed}`,
            derived: `expected=${control.expected} -> ${entry.match ? 'MATCH' : 'MISMATCH'}`,
            verdict: entry.match ? 'PASS' : 'FAIL',
          });
        }
      } catch (error) {
        collector.row({
          block: finalizedLabel,
          raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
          derived: 'control read failed: slot checks cannot be trusted',
          verdict: 'INCONCLUSIVE',
        });
      }
    }
    outcomes.push(collector.finish());
  }
  for (const pin of pins.contracts) {
    outcomes.push(await checkContractBasics(arc, pin, pins, finalizedLabel, controlTrusted));
    outcomes.push(await checkProxyLinkage(arc, pin, finalizedLabel, controlTrusted));
  }
  outcomes.push(checkCardContracts(cardJson, pins, derivedArcAddress));
  outcomes.push(await checkUpgradedScan(arc, pins, finalizedNumber));
  {
    const collector = new EvidenceCollector('arc-statements', 'required disclosures (C5)', 'verifier plan');
    for (const statement of ARC_LIMITATIONS) {
      collector.row({
        block: finalizedLabel,
        raw: statement,
        derived: 'disclosed limitation',
        verdict: 'PASS',
      });
    }
    outcomes.push(collector.finish());
  }
  return finish(controlTrusted, pins);
}

/**
 * Composite run: Concordium first, then Arc only when Concordium passed
 * and produced the card plus the derived address. Shared artifacts avoid
 * re-reading chain state between the two halves.
 */
export async function runAllChecks(
  deps: RunDependencies,
  arc: ArcReads,
  pinsText: string,
): Promise<VerifierReport> {
  const concordium = await runConcordiumChecksWithArtifacts(deps);
  if (
    concordium.report.verdict !== 'PASS' ||
    concordium.cardJson === null ||
    concordium.derivedArcAddress === null
  ) {
    const collector = new EvidenceCollector('arc-skipped', 'run-order gate', 'orchestrator');
    collector.row({
      block: 'n/a',
      raw: `concordium verdict: ${concordium.report.verdict}`,
      derived: 'Concordium checks did not all pass: Arc checks not attempted',
      verdict: 'FAIL',
    });
    return aggregate([...concordium.report.checks, collector.finish()]);
  }
  const arcResult = await runArcChecks(arc, pinsText, concordium.cardJson, concordium.derivedArcAddress);
  return aggregate([...concordium.report.checks, ...arcResult.report.checks]);
}

export { printReport, reportToJson, aggregate };
