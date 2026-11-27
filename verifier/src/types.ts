/**
 * Shared verifier types. Every check produces evidence rows; verdicts are
 * PASS, FAIL, or INCONCLUSIVE. Anything that cannot be proven is never PASS.
 */

export type Verdict = 'PASS' | 'FAIL' | 'INCONCLUSIVE';

/**
 * One recorded observation. `raw` is exactly what the transport returned
 * (or a faithful rendering of it); `derived` is what the verifier computed
 * from it. Both are printed so an independent reviewer can re-check.
 */
export interface EvidenceRow {
  readonly check: string;
  readonly source: string;
  readonly endpoint: string;
  readonly block: string;
  readonly raw: string;
  readonly derived: string;
  readonly verdict: Verdict;
}

export interface CheckOutcome {
  readonly name: string;
  readonly verdict: Verdict;
  readonly rows: readonly EvidenceRow[];
  readonly notes: readonly string[];
}

export interface VerifierReport {
  readonly verdict: Verdict;
  readonly startedAt: string;
  readonly checks: readonly CheckOutcome[];
}

/** Machine-readable JSON form of a report (same shape, no methods). */
export type VerifierReportJSON = VerifierReport;
