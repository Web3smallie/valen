import { describe, expect, it } from 'vitest';
import { ChallengeService, MemoryChallengeStore } from './challenge.js';
import { ConcordiumError } from './types.js';

function expectCode(fn: () => unknown, code: string): void {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

describe('ChallengeService', () => {
  it('issues unique unpredictable challenges bound to the label', () => {
    const service = new ChallengeService(600_000);
    const seen = new Set<string>();
    for (let i = 0; i < 200; i += 1) {
      const issued = service.issue('session-1');
      expect(issued.secretHex).toMatch(/^[0-9a-f]{64}$/);
      expect(issued.id).toMatch(/^[0-9a-f]{32}$/);
      expect(seen.has(issued.secretHex)).toBe(false);
      seen.add(issued.secretHex);
    }
  });

  it('consumes exactly once and returns label plus issued context', () => {
    const service = new ChallengeService(600_000);
    const issued = service.issue('acct-A', '{"policy":1}');
    const consumed = service.consume(issued.id, issued.secretHex, 'acct-A');
    expect(consumed).toEqual({ label: 'acct-A', contextJson: '{"policy":1}' });
    expectCode(() => service.consume(issued.id, issued.secretHex, 'acct-A'), 'CHALLENGE_REUSED');
  });

  it('rejects unknown ids and wrong secrets without distinguishing them', () => {
    const service = new ChallengeService(600_000);
    const issued = service.issue('acct-A');
    expectCode(() => service.consume('0'.repeat(32), issued.secretHex, 'acct-A'), 'CHALLENGE_UNKNOWN');
    expectCode(() => service.consume(issued.id, 'f'.repeat(64), 'acct-A'), 'CHALLENGE_UNKNOWN');
    expectCode(() => service.consume(issued.id, 'not-hex', 'acct-A'), 'CHALLENGE_UNKNOWN');
    // Failed attempts must not consume the challenge.
    expect(service.consume(issued.id, issued.secretHex, 'acct-A').label).toBe('acct-A');
  });

  it('rejects cross-label (cross-session) substitution', () => {
    const service = new ChallengeService(600_000);
    const issued = service.issue('session-A');
    expectCode(() => service.consume(issued.id, issued.secretHex, 'session-B'), 'CHALLENGE_LABEL_MISMATCH');
    expect(service.consume(issued.id, issued.secretHex, 'session-A').label).toBe('session-A');
  });

  it('enforces expiry with an injectable clock', () => {
    let now = 1_700_000_000_000;
    const service = new ChallengeService(60_000, new MemoryChallengeStore(), () => now);
    const issued = service.issue('acct-A');
    now += 60_001;
    expectCode(() => service.consume(issued.id, issued.secretHex, 'acct-A'), 'CHALLENGE_EXPIRED');
  });

  it('rejects empty labels and non-positive ttls at construction', () => {
    const service = new ChallengeService(60_000);
    expectCode(() => service.issue(''), 'CHALLENGE_LABEL_MISMATCH');
    expectCode(() => new ChallengeService(0), 'CHALLENGE_EXPIRED');
  });
});
