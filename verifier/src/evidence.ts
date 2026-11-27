import type { CheckOutcome, EvidenceRow, Verdict } from './types.js';

/**
 * Collects evidence rows for one check. Rows are append-only: once recorded
 * they are never edited, so the report always shows what was observed.
 */
export class EvidenceCollector {
  private readonly rows: EvidenceRow[] = [];
  private readonly notes: string[] = [];

  constructor(
    private readonly check: string,
    private readonly source: string,
    private readonly endpoint: string,
  ) {}

  row(input: {
    readonly block: string;
    readonly raw: string;
    readonly derived: string;
    readonly verdict: Verdict;
  }): void {
    this.rows.push({
      check: this.check,
      source: this.source,
      endpoint: this.endpoint,
      block: input.block,
      raw: input.raw,
      derived: input.derived,
      verdict: input.verdict,
    });
  }

  note(text: string): void {
    this.notes.push(text);
  }

  /** Worst verdict wins: FAIL beats INCONCLUSIVE beats PASS. An empty check is INCONCLUSIVE, never PASS. */
  finish(): CheckOutcome {
    let verdict: Verdict = this.rows.length === 0 ? 'INCONCLUSIVE' : 'PASS';
    for (const row of this.rows) {
      if (row.verdict === 'FAIL') {
        verdict = 'FAIL';
        break;
      }
      if (row.verdict === 'INCONCLUSIVE') {
        verdict = 'INCONCLUSIVE';
      }
    }
    return { name: this.check, verdict, rows: [...this.rows], notes: [...this.notes] };
  }
}
