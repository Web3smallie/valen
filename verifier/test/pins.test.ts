import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { loadArcPinsFile } from '../src/arc/contracts.js';
import { UPGRADED_TOPIC0 } from '../src/arc/upgrades.js';

const here = dirname(fileURLToPath(import.meta.url));
const PINS_TEXT = readFileSync(join(here, '..', 'pins', 'arc-testnet.json'), 'utf8');
const PINS_RAW = JSON.parse(PINS_TEXT) as Record<string, unknown>;

describe('pins file', () => {
  it('loads and carries the expected chain, owner, and 11 contracts', () => {
    const pins = loadArcPinsFile(PINS_TEXT);
    expect(pins.chainId).toBe(5042002);
    expect(pins.owner.toLowerCase()).toBe('0xb0e8ba6afe21371ad4001e611224fc200fd10144');
    expect(pins.contracts.length).toBe(11);
    expect(pins.proxyCodeBytes).toBe(212);
    expect(pins.scan.lastVerifiedBlock).toBe(74164159);
    expect(pins.scan.maxChunkBlocks).toBeLessThanOrEqual(9999);
    const names = pins.contracts.map((entry) => entry.name).sort();
    expect(names).toEqual(
      [
        'ActivityAttester',
        'AgentRegistry',
        'CollateralVault',
        'CreditRegistry',
        'LiquidityPool',
        'LoanRegistry',
        'LoanVault',
        'RecipientRegistry',
        'ReservePool',
        'RevenueRouter',
        'UnderwriterPool',
      ].sort(),
    );
  });

  it('scan topic matches the independently computed Upgraded topic', () => {
    const pins = loadArcPinsFile(PINS_TEXT);
    expect(pins.scan.upgradedTopic0.toLowerCase()).toBe(UPGRADED_TOPIC0);
  });

  it('header records source build and the update-after-upgrade note', () => {
    const header = PINS_RAW['_header'] as Record<string, unknown>;
    expect(header['sourceCommit']).toBe('abd4225');
    expect(String(header['note'])).toMatch(/updated when any upgrade is run/i);
    const scan = PINS_RAW['scan'] as Record<string, unknown>;
    expect(String(scan['pinnedHistoryNote'])).toMatch(/not re-verified/i);
  });

  it('rejects non-JSON text', () => {
    expect(() => loadArcPinsFile('not json{{{')).toThrow();
  });

  it('rejects a malformed contract entry', () => {
    const broken = { ...(PINS_RAW as object), contracts: [{ name: 'LoanRegistry' }] };
    expect(() => loadArcPinsFile(JSON.stringify(broken))).toThrow(/malformed contract entry/);
  });

  it('rejects missing top-level fields', () => {
    const broken = { ...(PINS_RAW as object) };
    delete (broken as Record<string, unknown>)['proxyCodeHash'];
    expect(() => loadArcPinsFile(JSON.stringify(broken))).toThrow(/top-level/);
  });
});
