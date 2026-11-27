import { describe, expect, it } from 'vitest';
import {
  buildValenAtomicStatements,
  buildWalletCredentialStatement,
  canonicalJson,
  statementsEqual,
} from './policy.js';

describe('statement policy', () => {
  it('builds a dob range proving adulthood with zero disclosure', () => {
    // 2026-11-22 minus 18 years -> upper bound 20081122.
    const statements = buildValenAtomicStatements(Date.UTC(2026, 10, 22));
    expect(statements).toEqual([
      { type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081122' },
    ]);
  });

  it('builds the wallet request with the pinned IDP allowlist', () => {
    const credentialStatement = buildWalletCredentialStatement(
      [0],
      buildValenAtomicStatements(Date.UTC(2026, 10, 22)),
    );
    expect(credentialStatement.idQualifier).toEqual({ type: 'cred', issuers: [0] });
    expect(credentialStatement.statement).toHaveLength(1);
  });

  it('compares statements canonically (key order free, value strict)', () => {
    const a = [{ type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081122' }];
    const reordered = [{ upper: '20081122', lower: '18000101', attributeTag: 'dob', type: 'AttributeInRange' }];
    const tampered = [{ type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081123' }];
    expect(statementsEqual(a, reordered)).toBe(true);
    expect(statementsEqual(a, tampered)).toBe(false);
    expect(statementsEqual(a, [])).toBe(false);
    expect(canonicalJson({ b: 1, a: [3, 2] })).toBe('{"a":[3,2],"b":1}');
  });
});
