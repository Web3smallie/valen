import type { CheckOutcome, Verdict, VerifierReport, VerifierReportJSON } from './types.js';

/**
 * Aggregates check outcomes into a final verdict. Fail-closed: any FAIL
 * means FAIL, and any INCONCLUSIVE on a required check means FAIL.
 * Callers pass exactly the required checks, so INCONCLUSIVE anywhere fails.
 */
export function aggregate(checks: readonly CheckOutcome[]): VerifierReport {
  let verdict: Verdict = checks.length === 0 ? 'INCONCLUSIVE' : 'PASS';
  for (const check of checks) {
    if (check.verdict === 'FAIL') {
      verdict = 'FAIL';
      break;
    }
    if (check.verdict === 'INCONCLUSIVE') {
      verdict = 'INCONCLUSIVE';
    }
  }
  if (verdict === 'INCONCLUSIVE') {
    verdict = 'FAIL';
  }
  return { verdict, startedAt: new Date().toISOString(), checks: [...checks] };
}

export function reportToJson(report: VerifierReport): VerifierReportJSON {
  return JSON.parse(JSON.stringify(report)) as VerifierReportJSON;
}

/** Human-readable rendering: every value printed so it can be re-checked by hand. */
export function printReport(report: VerifierReport): string {
  const lines: string[] = [`VERDICT: ${report.verdict}`, `started: ${report.startedAt}`, ''];
  for (const check of report.checks) {
    lines.push(`## ${check.name}: ${check.verdict}`);
    for (const row of check.rows) {
      lines.push(`  [${row.verdict}] ${row.source} @ ${row.block}`);
      lines.push(`    endpoint: ${row.endpoint}`);
      lines.push(`    raw:      ${row.raw}`);
      lines.push(`    derived:  ${row.derived}`);
    }
    for (const note of check.notes) {
      lines.push(`  note: ${note}`);
    }
    lines.push('');
  }
  return lines.join('\n');
}
