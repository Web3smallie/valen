/**
 * Valen's Concordium statement policy.
 *
 * What Valen requires a borrower operator to prove, with zero attribute
 * disclosure:
 * - Credential issued by an allowlisted identity provider (enforced via
 *   `idQualifier.issuers` at request time AND re-checked against live
 *   on-chain credential data at verification time — wallet filtering
 *   alone is never trusted).
 * - A date-of-birth range proof showing adulthood (18+). This is the
 *   least-disclosing predicate executable against real credentials: it
 *   reveals only that a bound holds, never the underlying value.
 *
 * The statement is bound to the issued challenge at request time: the
 * verifier compares the proven statements against the issued snapshot,
 * never against a mutable global, so policy rotations cannot be confused
 * across in-flight sessions.
 */

export interface ValenAtomicStatement {
  readonly type: 'AttributeInRange';
  readonly attributeTag: 'dob';
  readonly lower: string;
  readonly upper: string;
}

export interface ValenCredentialStatement {
  readonly idQualifier: {
    readonly type: 'cred';
    readonly issuers: readonly number[];
  };
  readonly statement: readonly ValenAtomicStatement[];
}

function toDateOnly(ms: number): string {
  const d = new Date(ms);
  const y = d.getUTCFullYear().toString().padStart(4, '0');
  const m = (d.getUTCMonth() + 1).toString().padStart(2, '0');
  const day = d.getUTCDate().toString().padStart(2, '0');
  return `${y}${m}${day}`;
}

/**
 * Build the atomic statements for a fresh issuance moment. The upper bound
 * is computed as (today - 18 years) so "adult" stays correct over time.
 */
export function buildValenAtomicStatements(nowMs: number): ValenAtomicStatement[] {
  const d = new Date(nowMs);
  const cutoff = Date.UTC(d.getUTCFullYear() - 18, d.getUTCMonth(), d.getUTCDate());
  return [
    {
      type: 'AttributeInRange',
      attributeTag: 'dob',
      lower: '18000101',
      upper: toDateOnly(cutoff),
    },
  ];
}

/** Build the wallet-request payload: allowlisted issuers + atomic statements. */
export function buildWalletCredentialStatement(
  idpAllowlist: readonly number[],
  statements: readonly ValenAtomicStatement[],
): ValenCredentialStatement {
  return {
    idQualifier: { type: 'cred', issuers: [...idpAllowlist] },
    statement: [...statements],
  };
}

/** Canonical JSON: object keys sorted recursively. Used for exact matching. */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') {
    return JSON.stringify(value) ?? 'null';
  }
  if (Array.isArray(value)) {
    return `[${value.map((entry) => canonicalJson(entry)).join(',')}]`;
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  const parts = keys.map(
    (key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`,
  );
  return `{${parts.join(',')}}`;
}

/** Order-sensitive deep equality over the canonical form. */
export function statementsEqual(a: unknown, b: unknown): boolean {
  return canonicalJson(a) === canonicalJson(b);
}
