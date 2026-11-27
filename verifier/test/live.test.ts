import { execFile } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  LiveArcReads,
  LiveConcordiumNode,
  printReport,
  runAllChecks,
  runConcordiumChecks,
} from '../src/index.js';

/**
 * Trial live run against Concordium testnet. Gated: only runs with
 * VERIFIER_LIVE=1. Read-only (node invokes + one HTTPS fetch). This is a
 * trial run for development, not the final recorded run.
 *
 * Sandbox note: this sandbox blocks Node's DNS while curl works through
 * the proxy. The second test below therefore injects a curl-backed fetch
 * (same URL, same bytes, same policy checks inside fetchCard); in any
 * normal environment the plain global-fetch run passes as written.
 */
const LIVE = process.env['VERIFIER_LIVE'] === '1';

/** Test-only fetch via curl: honors redirect rejection (no -L) and surfaces status codes. */
function curlFetch(url: string): Promise<Response> {
  return new Promise((resolve, reject) => {
    execFile(
      'curl',
      ['-s', '-m', '25', url, '-o', '-', '-w', '\n%{http_code}'],
      { encoding: 'buffer', maxBuffer: 2 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          reject(new Error(`curl failed: ${String(error.message).slice(0, 100)}`));
          return;
        }
        const out = stdout as unknown as Buffer;
        const text = out.toString('utf8');
        const match = /\n(\d{3})$/.exec(text);
        if (!match?.[1]) {
          reject(new Error('curl output unparseable'));
          return;
        }
        const body = out.subarray(0, out.length - 4);
        resolve(new Response(new Uint8Array(body), { status: Number(match[1]) }));
      },
    );
  });
}

describe.skipIf(!LIVE)('live trial run (testnet, read-only)', () => {
  it('chain reads pass with global fetch; card fetch outcome is reported, not asserted (sandbox DNS)', async () => {
    const report = await runConcordiumChecks({ node: new LiveConcordiumNode() });
    console.log(printReport(report));
    const byName = Object.fromEntries(report.checks.map((c) => [c.name, c.verdict]));
    // Chain reads must pass everywhere; the HTTPS leg depends on ambient DNS.
    expect(byName['1-badge']).toBe('PASS');
    expect(byName['2-agentOf']).toBe('PASS');
  }, 120000);

  it('verifies end to end via curl-backed fetch (sandbox DNS workaround)', async () => {
    const report = await runConcordiumChecks({ node: new LiveConcordiumNode(), fetchFn: curlFetch });
    console.log(printReport(report));
    expect(report.verdict).toBe('PASS');
  }, 120000);
});

/** Test-only fetch-compatible POST via curl, for injecting into viem's http transport. */
function curlPost(input: string, init?: { method?: string; body?: unknown }): Promise<Response> {
  const body = typeof init?.body === 'string' ? init.body : '';
  return new Promise((resolve, reject) => {
    execFile(
      'curl',
      [
        '-s',
        '-m',
        '40',
        '-X',
        'POST',
        input,
        '-H',
        'Content-Type: application/json',
        '--data-binary',
        body,
        '-o',
        '-',
        '-w',
        '\n%{http_code}',
      ],
      { encoding: 'buffer', maxBuffer: 16 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          reject(new Error(`curl post failed: ${String(error.message).slice(0, 100)}`));
          return;
        }
        const out = stdout as unknown as Buffer;
        const text = out.toString('utf8');
        const match = /\n(\d{3})$/.exec(text);
        if (!match?.[1]) {
          reject(new Error('curl post output unparseable'));
          return;
        }
        const responseBody = out.subarray(0, out.length - 4);
        resolve(new Response(new Uint8Array(responseBody), { status: Number(match[1]) }));
      },
    );
  });
}

const PINS_TEXT = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), '..', 'pins', 'arc-testnet.json'),
  'utf8',
);

describe.skipIf(!LIVE)('live trial run, all checks (testnet, read-only)', () => {
  it('global fetch first: chain reads asserted, network legs reported (sandbox DNS)', async () => {
    const report = await runAllChecks({ node: new LiveConcordiumNode() }, new LiveArcReads(), PINS_TEXT);
    console.log(printReport(report));
    const byName = Object.fromEntries(report.checks.map((c) => [c.name, c.verdict]));
    expect(byName['1-badge']).toBe('PASS');
    expect(byName['2-agentOf']).toBe('PASS');
  }, 300000);

  it('composite run via injected fetch (sandbox DNS workaround)', async () => {
    const report = await runAllChecks(
      { node: new LiveConcordiumNode(), fetchFn: curlFetch },
      new LiveArcReads('https://rpc.testnet.arc.io', curlPost as typeof fetch),
      PINS_TEXT,
    );
    console.log(printReport(report));
    expect(report.verdict).toBe('PASS');
  }, 300000);
});
