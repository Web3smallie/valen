/**
 * Single-use, expiring, label-bound challenge service.
 *
 * Used for identity-presentation challenges and (via a separate instance
 * with a distinct label namespace) EVM co-signature nonces.
 *
 * Security properties:
 * - 256-bit cryptographically secure secrets (`crypto.randomBytes`).
 * - A challenge is usable exactly once: `consume` marks it spent.
 * - Every challenge carries an expiry enforced at consume time.
 * - Every challenge is bound to a caller-chosen label (e.g. the session
 *   id or expected account). Consuming under a different label fails,
 *   which prevents cross-session substitution.
 *
 * The default store is in-memory and single-process. Production deployments
 * spanning processes MUST supply a shared store implementing the same
 * interface; the service itself is store-agnostic.
 */

import { randomBytes, timingSafeEqual } from 'node:crypto';
import { ConcordiumError, type Clock, type UnixMs } from './types.js';

export interface ChallengeRecord {
  readonly id: string;
  readonly secretHex: string;
  readonly label: string;
  /**
   * Opaque server-side context bound at issuance (for identity challenges:
   * the canonical statement snapshot). Returned verbatim on consume so the
   * verifier compares proofs against what was ISSUED, never a mutable global.
   */
  readonly contextJson: string;
  readonly createdAtMs: UnixMs;
  readonly expiresAtMs: UnixMs;
  consumed: boolean;
}

export interface ConsumedChallenge {
  readonly label: string;
  readonly contextJson: string;
}

export interface ChallengeStore {
  save(record: ChallengeRecord): void;
  load(id: string): ChallengeRecord | undefined;
  markConsumed(id: string): void;
  prune(nowMs: UnixMs): void;
}

export class MemoryChallengeStore implements ChallengeStore {
  private readonly records = new Map<string, ChallengeRecord>();

  save(record: ChallengeRecord): void {
    this.records.set(record.id, { ...record });
  }

  load(id: string): ChallengeRecord | undefined {
    const found = this.records.get(id);
    return found === undefined ? undefined : { ...found };
  }

  markConsumed(id: string): void {
    const found = this.records.get(id);
    if (found !== undefined) {
      this.records.set(id, { ...found, consumed: true });
    }
  }

  prune(nowMs: UnixMs): void {
    for (const [id, record] of this.records) {
      if (record.expiresAtMs <= nowMs) {
        this.records.delete(id);
      }
    }
  }
}

export interface IssuedChallenge {
  /** Public handle (safe to log). */
  readonly id: string;
  /** 64 lowercase hex chars. Presented to the wallet as the proof challenge. */
  readonly secretHex: string;
  readonly expiresAtMs: UnixMs;
}

function isHex64(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

export class ChallengeService {
  private readonly store: ChallengeStore;
  private readonly ttlMs: number;
  private readonly now: Clock;
  private readonly randomHex: (bytes: number) => string;

  constructor(
    ttlMs: number,
    store: ChallengeStore = new MemoryChallengeStore(),
    now: Clock = Date.now,
    randomHex: (bytes: number) => string = (bytes: number) =>
      randomBytes(bytes).toString('hex'),
  ) {
    if (!Number.isInteger(ttlMs) || ttlMs <= 0) {
      throw new ConcordiumError('CHALLENGE_EXPIRED', 'ttl must be positive');
    }
    this.ttlMs = ttlMs;
    this.store = store;
    this.now = now;
    this.randomHex = randomHex;
  }

  /** Issue a fresh challenge bound to `label`, snapshotting `contextJson`. */
  issue(label: string, contextJson = ''): IssuedChallenge {
    if (label.length === 0) {
      throw new ConcordiumError('CHALLENGE_LABEL_MISMATCH', 'label required');
    }
    const createdAtMs = this.now();
    const record: ChallengeRecord = {
      id: this.randomHex(16),
      secretHex: this.randomHex(32),
      label,
      contextJson,
      createdAtMs,
      expiresAtMs: createdAtMs + this.ttlMs,
      consumed: false,
    };
    this.store.save(record);
    this.store.prune(createdAtMs);
    return { id: record.id, secretHex: record.secretHex, expiresAtMs: record.expiresAtMs };
  }

  /**
   * Consume a challenge. Returns the bound label and issued context snapshot.
   * Throws on unknown id, secret mismatch, label mismatch, expiry, or reuse.
   */
  consume(id: string, secretHex: string, label: string): ConsumedChallenge {
    const record = this.store.load(id);
    if (record === undefined) {
      throw new ConcordiumError('CHALLENGE_UNKNOWN');
    }
    if (!isHex64(secretHex) || !isHex64(record.secretHex)) {
      throw new ConcordiumError('CHALLENGE_UNKNOWN');
    }
    const presented = Buffer.from(secretHex, 'hex');
    const expected = Buffer.from(record.secretHex, 'hex');
    if (presented.length !== expected.length || !timingSafeEqual(presented, expected)) {
      // Deliberately the same code as unknown id: callers must not learn
      // whether an id exists.
      throw new ConcordiumError('CHALLENGE_UNKNOWN');
    }
    if (record.label !== label) {
      throw new ConcordiumError('CHALLENGE_LABEL_MISMATCH');
    }
    if (record.consumed) {
      throw new ConcordiumError('CHALLENGE_REUSED');
    }
    if (this.now() > record.expiresAtMs) {
      throw new ConcordiumError('CHALLENGE_EXPIRED');
    }
    this.store.markConsumed(id);
    return { label: record.label, contextJson: record.contextJson };
  }
}
