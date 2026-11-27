import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { keccak256, toHex } from 'viem';
import { describe, expect, it } from 'vitest';
import {
  IMPL_SLOT,
  OWNABLE_SLOT,
  SELECTOR_OWNER,
  SELECTOR_UPGRADE_INTERFACE_VERSION,
  checkCardContracts,
  checkChainId,
  checkContractBasics,
  keccakOfCode,
  type ArcContractPin,
  type ArcPinsFile,
  type ArcReads,
} from '../src/arc/contracts.js';
import { checkProxyLinkage } from '../src/arc/proxies.js';
import { UPGRADED_TOPIC0 } from '../src/arc/upgrades.js';
import { runArcChecks } from '../src/index.js';

const here = dirname(fileURLToPath(import.meta.url));
const PINS_TEXT = readFileSync(join(here, '..', 'pins', 'arc-testnet.json'), 'utf8');
const HAPPY = JSON.parse(readFileSync(join(here, 'fixtures', 'arc-happy.json'), 'utf8')) as HappyFixture;
const REAL_CARD = JSON.parse(readFileSync(join(here, 'fixtures', 'agent-card.json'), 'utf8')) as unknown;

const OWNER = '0xb0e8ba6afe21371ad4001e611224fc200fd10144';
const PROXY = '0x1111111111111111111111111111111111111111';
const IMPL = '0x2222222222222222222222222222222222222222';
const PROXY_CODE = '0x6080604052600a600c565b005b60186014601a565b6026565b565b';
const IMPL_CODE = '0x6080604052348015600e575f5ffd5b5050602a8061001c5f395ff3fe';

interface HappyFixtureContract {
  readonly name: string;
  readonly proxy: string;
  readonly ownerReturn: string;
  readonly ownableSlot: string;
  readonly versionReturn: string;
  readonly implSlot: string;
  readonly implCode: string;
}

interface HappyFixture {
  readonly chainId: number;
  readonly finalizedBlock: number;
  readonly owner: string;
  readonly proxyCode: string;
  readonly ownerCode: string;
  readonly contracts: readonly HappyFixtureContract[];
}

type LogEntry = { address: string; topics: readonly string[]; blockNumber: bigint };

interface StubWorld {
  chainId: number;
  chainIdError: string | null;
  finalized: bigint;
  finalizedError: string | null;
  code: Map<string, string>;
  codeErrors: Set<string>;
  calls: Map<string, string>;
  callErrors: Set<string>;
  slots: Map<string, string>;
  slotErrors: Set<string>;
  logs: LogEntry[] | 'ERROR';
}

function wordOfAddress(address: string): string {
  return `0x${'0'.repeat(24)}${address.slice(2).toLowerCase()}`;
}

function versionReturnOf(text: string): string {
  const data = Buffer.from(text, 'utf8');
  const padded = Buffer.alloc(32);
  data.copy(padded);
  const length = data.length.toString(16).padStart(64, '0');
  return `0x${'0'.repeat(62)}20${length}${padded.toString('hex')}`;
}

function makeWorld(): StubWorld {
  const ownerWord = wordOfAddress(OWNER);
  return {
    chainId: 5042002,
    chainIdError: null,
    finalized: 74164200n,
    finalizedError: null,
    code: new Map([
      [PROXY.toLowerCase(), PROXY_CODE],
      [IMPL.toLowerCase(), IMPL_CODE],
      [OWNER.toLowerCase(), '0x'],
    ]),
    codeErrors: new Set(),
    calls: new Map([
      [`${PROXY.toLowerCase()}:${SELECTOR_OWNER.toLowerCase()}`, ownerWord],
      [`${PROXY.toLowerCase()}:${SELECTOR_UPGRADE_INTERFACE_VERSION.toLowerCase()}`, versionReturnOf('5.0.0')],
    ]),
    callErrors: new Set(),
    slots: new Map([
      [`${PROXY.toLowerCase()}:${OWNABLE_SLOT.toLowerCase()}`, ownerWord],
      [`${PROXY.toLowerCase()}:${IMPL_SLOT.toLowerCase()}`, wordOfAddress(IMPL)],
    ]),
    slotErrors: new Set(),
    logs: [],
  };
}

function stubArc(world: StubWorld): { arc: ArcReads; reads: string[] } {
  const reads: string[] = [];
  const arc: ArcReads = {
    endpoint: 'stub',
    getChainId: async () => {
      reads.push('getChainId');
      if (world.chainIdError !== null) {
        throw new Error(world.chainIdError);
      }
      return world.chainId;
    },
    getFinalizedBlockNumber: async () => {
      reads.push('getFinalizedBlockNumber');
      if (world.finalizedError !== null) {
        throw new Error(world.finalizedError);
      }
      return world.finalized;
    },
    getCode: async (address) => {
      reads.push(`getCode:${address.toLowerCase()}`);
      if (world.codeErrors.has(address.toLowerCase())) {
        throw new Error('stub code failure');
      }
      const code = world.code.get(address.toLowerCase());
      if (code === undefined) {
        throw new Error(`stub has no code for ${address}`);
      }
      return code;
    },
    call: async (to, data) => {
      reads.push(`call:${to.toLowerCase()}:${data.toLowerCase()}`);
      const key = `${to.toLowerCase()}:${data.toLowerCase()}`;
      if (world.callErrors.has(key)) {
        throw new Error('stub call failure');
      }
      const out = world.calls.get(key);
      if (out === undefined) {
        throw new Error(`stub has no call result for ${key}`);
      }
      return out;
    },
    getStorageAt: async (address, slot) => {
      reads.push(`getStorageAt:${address.toLowerCase()}:${slot.toLowerCase()}`);
      const key = `${address.toLowerCase()}:${slot.toLowerCase()}`;
      if (world.slotErrors.has(key)) {
        throw new Error('stub slot failure');
      }
      const word = world.slots.get(key);
      if (word === undefined) {
        throw new Error(`stub has no slot for ${key}`);
      }
      return word;
    },
    getLogsByBlockRange: async () => {
      reads.push('getLogsByBlockRange');
      if (world.logs === 'ERROR') {
        throw new Error('stub logs failure');
      }
      return world.logs;
    },
  };
  return { arc, reads };
}

function singlePin(overrides: Partial<ArcContractPin> = {}): ArcContractPin {
  return {
    name: 'LoanRegistry',
    proxy: PROXY,
    implementation: IMPL,
    implementationCodeHash: keccakOfCode(IMPL_CODE),
    ...overrides,
  };
}

function singlePinsText(overrides: { contracts?: readonly ArcContractPin[] } = {}): string {
  const pins: ArcPinsFile = {
    chainId: 5042002,
    owner: OWNER,
    proxyCodeHash: keccakOfCode(PROXY_CODE),
    proxyCodeBytes: PROXY_CODE.length / 2 - 1,
    contracts: overrides.contracts ?? [singlePin()],
    scan: { lastVerifiedBlock: 74164159, upgradedTopic0: UPGRADED_TOPIC0, maxChunkBlocks: 9999 },
  };
  return JSON.stringify(pins);
}

function singleCard(ownerRef: string = OWNER, contracts: Record<string, string> | null = null): unknown {
  return {
    'x-valen': { contracts: contracts ?? { LoanRegistry: PROXY } },
    capabilities: {
      extensions: [
        {
          uri: 'https://docs.concordium.com/a2a-extensions/concordium-badge/v1',
          params: { externalReference: { identifier: ownerRef } },
        },
      ],
    },
  };
}

function outcome(report: { checks: readonly { name: string }[] }, name: string): number {
  const index = report.checks.findIndex((check) => check.name === name);
  expect(index, `missing outcome ${name}`).toBeGreaterThanOrEqual(0);
  return index;
}

describe('per-contract checks (unit level)', () => {
  it('proxy with zero code is FAIL', async () => {
    const world = makeWorld();
    world.code.set(PROXY.toLowerCase(), '0x');
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('proxy code hash mismatch is FAIL', async () => {
    const world = makeWorld();
    world.code.set(PROXY.toLowerCase(), '0x6001600101');
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('owner() mismatch is FAIL', async () => {
    const world = makeWorld();
    const stranger = wordOfAddress('0x3333333333333333333333333333333333333333');
    world.calls.set(`${PROXY.toLowerCase()}:${SELECTOR_OWNER.toLowerCase()}`, stranger);
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('non-EOA owner is FAIL', async () => {
    const world = makeWorld();
    world.code.set(OWNER.toLowerCase(), '0x60806040');
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('Ownable slot differing from owner() is FAIL when control is trusted', async () => {
    const world = makeWorld();
    world.slots.set(
      `${PROXY.toLowerCase()}:${OWNABLE_SLOT.toLowerCase()}`,
      wordOfAddress('0x4444444444444444444444444444444444444444'),
    );
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('UPGRADE_INTERFACE_VERSION mismatch is FAIL', async () => {
    const world = makeWorld();
    world.calls.set(
      `${PROXY.toLowerCase()}:${SELECTOR_UPGRADE_INTERFACE_VERSION.toLowerCase()}`,
      versionReturnOf('4.0.0'),
    );
    const { arc } = stubArc(world);
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    const result = await checkContractBasics(arc, singlePin(), pins, 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('implementation slot differing from pin is FAIL', async () => {
    const world = makeWorld();
    world.slots.set(
      `${PROXY.toLowerCase()}:${IMPL_SLOT.toLowerCase()}`,
      wordOfAddress('0x5555555555555555555555555555555555555555'),
    );
    const { arc } = stubArc(world);
    const result = await checkProxyLinkage(arc, singlePin(), 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });

  it('implementation code hash mismatch is FAIL', async () => {
    const world = makeWorld();
    world.code.set(IMPL.toLowerCase(), '0x6001600101');
    const { arc } = stubArc(world);
    const result = await checkProxyLinkage(arc, singlePin(), 'finalized #1', true);
    expect(result.verdict).toBe('FAIL');
  });
});

describe('run gates (runner level)', () => {
  it('wrong chain id fails before any contract read', async () => {
    const world = makeWorld();
    world.chainId = 1;
    const { arc, reads } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText(), singleCard(), OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-chain-id')]?.verdict).toBe('FAIL');
    expect(reads).toEqual(['getChainId']);
  });

  it('Upgraded event after the pinned block is FAIL', async () => {
    const world = makeWorld();
    world.logs = [{ address: PROXY, topics: [UPGRADED_TOPIC0], blockNumber: 74164160n }];
    const { arc } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText(), singleCard(), OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-upgrades-scan')]?.verdict).toBe('FAIL');
  });

  it('scan RPC error fails the run closed', async () => {
    const world = makeWorld();
    world.logs = 'ERROR';
    const { arc } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText(), singleCard(), OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-upgrades-scan')]?.verdict).toBe('INCONCLUSIVE');
  });

  it('control failure makes slot checks INCONCLUSIVE and fails overall', async () => {
    const world = makeWorld();
    world.slotErrors.add(`${PROXY.toLowerCase()}:${OWNABLE_SLOT.toLowerCase()}`);
    const { arc } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText(), singleCard(), OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.controlTrusted).toBe(false);
    expect(result.report.checks[outcome(result.report, 'arc-control')]?.verdict).toBe('INCONCLUSIVE');
    expect(result.report.checks[outcome(result.report, 'arc-LoanRegistry')]?.verdict).toBe('INCONCLUSIVE');
    expect(result.report.checks[outcome(result.report, 'arc-LoanRegistry-proxy')]?.verdict).toBe(
      'INCONCLUSIVE',
    );
  });

  it('card contract list differing from pins is FAIL', async () => {
    const world = makeWorld();
    const { arc } = stubArc(world);
    const card = singleCard(OWNER, {
      LoanRegistry: PROXY,
      PhantomRegistry: '0x6666666666666666666666666666666666666666',
    });
    const result = await runArcChecks(arc, singlePinsText(), card, OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-card-crosscheck')]?.verdict).toBe('FAIL');
  });

  it('card owner differing from the derived key is FAIL', async () => {
    const world = makeWorld();
    const { arc } = stubArc(world);
    const card = singleCard('0x7777777777777777777777777777777777777777');
    const result = await runArcChecks(arc, singlePinsText(), card, OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-card-crosscheck')]?.verdict).toBe('FAIL');
  });

  it('pins file missing the card contract is FAIL', async () => {
    const world = makeWorld();
    const { arc } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText({ contracts: [] }), singleCard(), OWNER);
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-card-crosscheck')]?.verdict).toBe('FAIL');
  });

  it('derived address disagreeing with pins owner is FAIL before any read', async () => {
    const world = makeWorld();
    const { arc, reads } = stubArc(world);
    const result = await runArcChecks(
      arc,
      singlePinsText(),
      singleCard(),
      '0x8888888888888888888888888888888888888888',
    );
    expect(result.report.verdict).toBe('FAIL');
    expect(result.report.checks[outcome(result.report, 'arc-owner-pin')]?.verdict).toBe('FAIL');
    expect(reads).toEqual([]);
  });
});

describe('scan mechanics', () => {
  it('Upgraded topic equals keccak256("Upgraded(address)")', () => {
    expect(UPGRADED_TOPIC0).toBe(keccak256(toHex('Upgraded(address)')));
    expect(UPGRADED_TOPIC0).toBe('0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b');
  });

  it('scan walks the range in bounded chunks', async () => {
    const world = makeWorld();
    world.finalized = 74164159n + 25000n;
    world.logs = [];
    const { arc, reads } = stubArc(world);
    const result = await runArcChecks(arc, singlePinsText(), singleCard(), OWNER);
    expect(result.report.verdict).toBe('PASS');
    const scanCalls = reads.filter((entry) => entry === 'getLogsByBlockRange');
    expect(scanCalls.length).toBe(3); // ceil(25000 / 9999)
    const scan = result.report.checks[outcome(result.report, 'arc-upgrades-scan')];
    expect(scan?.rows[0]?.derived).toBe('no Upgraded events from block 74164160 to 74189159');
  });
});

describe('cross-check helper', () => {
  it('matching card and pins pass', () => {
    const pins = JSON.parse(singlePinsText()) as ArcPinsFile;
    expect(checkCardContracts(singleCard(), pins, OWNER).verdict).toBe('PASS');
  });

  it('chain gate passes on the pinned id', async () => {
    const world = makeWorld();
    const { arc } = stubArc(world);
    expect((await checkChainId(arc, 5042002)).verdict).toBe('PASS');
  });
});

describe('happy path from captured live reads', () => {
  function happyStub(): { arc: ArcReads; reads: string[] } {
    const code = new Map<string, string>();
    const calls = new Map<string, string>();
    const slots = new Map<string, string>();
    for (const entry of HAPPY.contracts) {
      const proxy = entry.proxy.toLowerCase();
      code.set(proxy, HAPPY.proxyCode);
      calls.set(`${proxy}:${SELECTOR_OWNER.toLowerCase()}`, entry.ownerReturn);
      calls.set(`${proxy}:${SELECTOR_UPGRADE_INTERFACE_VERSION.toLowerCase()}`, entry.versionReturn);
      slots.set(`${proxy}:${OWNABLE_SLOT.toLowerCase()}`, entry.ownableSlot);
      slots.set(`${proxy}:${IMPL_SLOT.toLowerCase()}`, entry.implSlot);
    }
    const pins = JSON.parse(PINS_TEXT) as ArcPinsFile;
    for (const pin of pins.contracts) {
      const frozen = HAPPY.contracts.find((entry) => entry.name === pin.name);
      expect(frozen, `fixture covers ${pin.name}`).toBeDefined();
      code.set(pin.implementation.toLowerCase(), frozen?.implCode ?? '0x');
    }
    code.set(HAPPY.owner.toLowerCase(), HAPPY.ownerCode);
    const world: StubWorld = {
      chainId: HAPPY.chainId,
      chainIdError: null,
      finalized: BigInt(HAPPY.finalizedBlock),
      finalizedError: null,
      code,
      codeErrors: new Set(),
      calls,
      callErrors: new Set(),
      slots,
      slotErrors: new Set(),
      logs: [],
    };
    return stubArc(world);
  }

  it('real pins + frozen live values + real card pass end to end', async () => {
    const { arc, reads } = happyStub();
    const result = await runArcChecks(arc, PINS_TEXT, REAL_CARD, OWNER);
    expect(result.report.verdict).toBe('PASS');
    expect(result.controlTrusted).toBe(true);
    for (const check of result.report.checks) {
      expect(check.verdict, `check ${check.name}`).toBe('PASS');
    }
    const scan = result.report.checks[outcome(result.report, 'arc-upgrades-scan')];
    const from = 74164159 + 1;
    const to = HAPPY.finalizedBlock;
    expect(scan?.rows[0]?.derived).toBe(`no Upgraded events from block ${from} to ${to}`);
    const chunks = Math.ceil((to - from + 1) / 9999);
    expect(reads.filter((entry) => entry === 'getLogsByBlockRange').length).toBe(chunks);
  });
});
