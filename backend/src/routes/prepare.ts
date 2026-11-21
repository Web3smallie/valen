/**
 * POST /loans/prepare
 *
 * Validates a LoanProposal and returns the ABI-encoded calldata the agent must
 * sign and broadcast itself. The backend NEVER signs or broadcasts.
 *
 * ABI versioning
 * ──────────────
 * V3 (deployed): LoanRegistryDeployedAbi — 15-field LoanProposal, selector
 *   matching the V3 implementation currently on Arc Testnet proxy
 *   0x253B68c7a2D646561387Dc0958A6C176a30a6f8d.
 *   directDisbursement is NOT a valid field and is rejected if supplied.
 *
 * V4 (pending upgrade): LoanRegistryAbi — 16-field LoanProposal, adds
 *   directDisbursement as the final bool.
 *
 * Target comes from the deployment manifest (abiVersion) — the single
 * source of truth. Flip it to "V4" only AFTER the V4 upgrade is confirmed
 * on-chain — see docs/v4-upgrade-runbook.md. The optional route option
 * exists for tests only; production always uses the manifest value.
 */
import type { FastifyInstance } from "fastify";
import { encodeFunctionData, isAddress } from "viem";
import { contracts, ABI_VERSION } from "../config/contracts.js";
import type { AbiVersion } from "../config/manifest.js";
import { LoanRegistryDeployedAbi } from "../abis/LoanRegistryDeployed.js";
import { LoanRegistryAbi }         from "../abis/LoanRegistry.js";
import { CollateralVaultAbi }      from "../abis/CollateralVault.js";
import { readContract }            from "../lib/rpc.js";
import { ValidationError, formatUnits6 } from "../lib/format.js";

interface BudgetCategory { categoryId: string; cap: string }

interface ProposalBody {
  agentId:               string | number;
  creditWallet:          string;
  principal:             string;         // raw uint256 string, 6-decimal USDC
  repaymentRateBps:      number;
  totalRepaymentDue:     string;
  duration:              string;         // seconds as a string
  purpose:               string;
  budget:                BudgetCategory[];
  permittedRecipients:   string[];
  milestoneAmounts:      string[];
  milestoneDescriptions: string[];
  collateralAmount:      string;
  collateralAsset:       string;
  underwriter?:          string;
  underwriterAmount?:    string;
  // directDisbursement is NOT accepted — it is not part of the deployed ABI.
  // Submit with directDisbursement set to anything and the request is rejected.
  directDisbursement?:   unknown;
}

export async function prepareRoutes(
  app: FastifyInstance,
  opts?: { abiVersion?: AbiVersion }
) {
  // Production always uses the manifest value; the option exists so tests
  // can exercise both encodings without environment overrides.
  const useV4 = (opts?.abiVersion ?? ABI_VERSION) === "V4";

  app.post<{ Body: ProposalBody }>("/loans/prepare", async (req, reply) => {
    const b = req.body ?? {};
    const errs: string[] = [];

    // ── directDisbursement handling ───────────────────────────────────────────
    // V3: not in the deployed contract — reject if supplied. V4: optional
    // boolean, validated by type (no policy restriction is imposed here).
    let directDisbursement = false;
    if (useV4) {
      if (b.directDisbursement !== undefined) {
        if (typeof b.directDisbursement !== "boolean") {
          errs.push("directDisbursement must be a boolean");
        } else {
          directDisbursement = b.directDisbursement;
        }
      }
    } else if (b.directDisbursement !== undefined) {
      return reply.code(400).send({
        error: "directDisbursement is not supported by the currently deployed LoanRegistry (V3). " +
               "Remove this field. It will become available after the V4 upgrade is deployed on-chain.",
      });
    }

    // ── Validate required fields ──────────────────────────────────────────────
    // Every untrusted numeric is parsed here so nothing below can throw.
    let agentId = 0n;
    if (b.agentId == null || b.agentId === "") {
      errs.push("agentId is required");
    } else {
      try {
        agentId = BigInt(b.agentId);
        if (agentId < 0n) errs.push("agentId must be a non-negative integer");
      } catch { errs.push("agentId must be a valid integer"); }
    }
    if (!isAddress(b.creditWallet ?? ""))        errs.push("creditWallet must be a valid address");

    let principal = 0n;
    try {
      principal = BigInt(b.principal ?? "");
      if (principal <= 0n) errs.push("principal must be > 0");
    } catch { errs.push("principal must be a valid integer string"); }

    if (!Number.isInteger(b.repaymentRateBps) || b.repaymentRateBps <= 0 || b.repaymentRateBps > 65535)
      errs.push("repaymentRateBps must be a positive uint16 integer (1–65535)");

    let totalRepaymentDue = 0n;
    try {
      totalRepaymentDue = BigInt(b.totalRepaymentDue ?? "");
      if (totalRepaymentDue < principal) errs.push("totalRepaymentDue must be >= principal");
    } catch { errs.push("totalRepaymentDue must be a valid integer string"); }

    let duration = 0n;
    try {
      duration = BigInt(b.duration ?? "");
      if (duration <= 0n) errs.push("duration must be > 0 seconds");
    } catch { errs.push("duration must be a valid integer string"); }

    if (!b.purpose?.trim()) errs.push("purpose is required");

    if (!Array.isArray(b.budget) || b.budget.length === 0)
      errs.push("budget must be a non-empty array");

    if (Array.isArray(b.budget)) {
      b.budget.forEach((c, i) => {
        if (!/^0x[0-9a-fA-F]{64}$/.test(c?.categoryId ?? "")) {
          errs.push(`budget[${i}].categoryId must be a valid bytes32 hex string`);
        }
      });
    }

    if (!Array.isArray(b.permittedRecipients) || b.permittedRecipients.length === 0)
      errs.push("permittedRecipients must be a non-empty array");

    if (Array.isArray(b.permittedRecipients)) {
      for (const r of b.permittedRecipients) {
        if (!isAddress(r)) errs.push(`permittedRecipients: "${r}" is not a valid address`);
      }
      // LoanRegistry requires the credit wallet to be a permitted recipient;
      // reject early instead of preparing calldata that would certainly revert.
      if (isAddress(b.creditWallet ?? "")) {
        const allowed = b.permittedRecipients.map((r) => String(r).toLowerCase());
        if (!allowed.includes((b.creditWallet as string).toLowerCase())) {
          errs.push("creditWallet must appear in permittedRecipients (required by LoanRegistry)");
        }
      }
    }

    if (!Array.isArray(b.milestoneAmounts) || b.milestoneAmounts.length === 0)
      errs.push("milestoneAmounts must be a non-empty array");

    if (!Array.isArray(b.milestoneDescriptions) ||
        b.milestoneDescriptions.length !== (b.milestoneAmounts?.length ?? 0))
      errs.push("milestoneDescriptions length must match milestoneAmounts length");

    if (!isAddress(b.collateralAsset ?? ""))
      errs.push("collateralAsset must be a valid address");

    let collateralAmount = 0n;
    try {
      collateralAmount = BigInt(b.collateralAmount ?? "0");
      if (collateralAmount < 0n) errs.push("collateralAmount must be >= 0");
    } catch { errs.push("collateralAmount must be a valid integer string"); }

    const underwriter = b.underwriter ?? "0x0000000000000000000000000000000000000000";
    if (!isAddress(underwriter)) errs.push("underwriter must be a valid address");

    let underwriterAmount = 0n;
    try {
      underwriterAmount = BigInt(b.underwriterAmount ?? "0");
      if (underwriterAmount < 0n) errs.push("underwriterAmount must be >= 0");
    } catch { errs.push("underwriterAmount must be a valid integer string"); }

    if (errs.length > 0) {
      return reply.code(400).send({ error: "Validation failed", details: errs });
    }

    const collateralAsset  = b.collateralAsset as `0x${string}`;

    // ── On-chain validation: collateral requirement ───────────────────────────
    if (collateralAmount > 0n) {
      let required: bigint;
      try {
        required = await readContract({
          address:      contracts.collateralVault,
          abi:          CollateralVaultAbi,
          functionName: "requiredCollateral",
          args:         [principal, collateralAsset],
        }) as bigint;
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return reply.code(502).send({
          error: "RPC error while checking collateral requirement",
          detail: msg,
        });
      }

      if (collateralAmount < required) {
        return reply.code(422).send({
          error:    "Insufficient collateral",
          required: { raw: required.toString(),        formatted: formatUnits6(required) },
          provided: { raw: collateralAmount.toString(), formatted: formatUnits6(collateralAmount) },
        });
      }
    }

    // ── Accounting invariant: budget sum must equal principal ─────────────────
    let budgetSum = 0n;
    try {
      budgetSum = (b.budget ?? []).reduce((acc, c) => acc + BigInt(c.cap), 0n);
    } catch {
      return reply.code(400).send({ error: "budget.cap values must be valid integer strings" });
    }
    if (budgetSum !== principal) {
      return reply.code(422).send({
        error:      "Budget cap sum must equal principal",
        principal:  principal.toString(),
        budgetSum:  budgetSum.toString(),
      });
    }

    // ── Accounting invariant: milestone sum must equal principal ──────────────
    let msSum = 0n;
    try {
      msSum = (b.milestoneAmounts ?? []).reduce((acc, a) => acc + BigInt(a), 0n);
    } catch {
      return reply.code(400).send({ error: "milestoneAmounts values must be valid integer strings" });
    }
    if (msSum !== principal) {
      return reply.code(422).send({
        error:        "Milestone amounts sum must equal principal",
        principal:    principal.toString(),
        milestoneSum: msSum.toString(),
      });
    }

    // ── Encode calldata ───────────────────────────────────────────────────────
    // All fields were validated above; the try/catch is defense-in-depth so an
    // encoding failure can never escape as a 500.
    const NOTE = "Sign and broadcast this transaction with the agent's own wallet. " +
                 "The backend does not sign or submit transactions.";

    // ── V4: 16-field proposal including directDisbursement ────────────────────
    if (useV4) {
      const proposal = {
        agentId,
        creditWallet:          b.creditWallet as `0x${string}`,
        principal,
        repaymentRateBps:      b.repaymentRateBps,
        totalRepaymentDue,
        duration,
        purpose:               b.purpose,
        budget:                (b.budget ?? []).map(c => ({
          categoryId: c.categoryId as `0x${string}`,
          cap:        BigInt(c.cap),
        })),
        permittedRecipients:   (b.permittedRecipients ?? []) as `0x${string}`[],
        milestoneAmounts:      (b.milestoneAmounts ?? []).map(BigInt),
        milestoneDescriptions: b.milestoneDescriptions ?? [],
        collateralAmount,
        collateralAsset,
        underwriter:      underwriter as `0x${string}`,
        underwriterAmount,
        directDisbursement,
      } as const;

      let calldata: string;
      try {
        calldata = encodeFunctionData({
          abi:          LoanRegistryAbi,
          functionName: "requestLoan",
          args:         [proposal],
        });
      } catch (e: unknown) {
        const msg = e instanceof Error ? e.message : String(e);
        return reply.code(400).send({ error: "Failed to encode proposal calldata", detail: msg });
      }

      return {
        to:       contracts.loanRegistry,
        calldata,
        value:    "0",
        abiVersion: "V4",
        directDisbursement,
        note:     NOTE,
      };
    }

    // ── V3 (deployed): 15-field proposal, no directDisbursement ───────────────
    const proposal = {
      agentId,
      creditWallet:          b.creditWallet as `0x${string}`,
      principal,
      repaymentRateBps:      b.repaymentRateBps,
      totalRepaymentDue,
      duration,
      purpose:               b.purpose,
      budget:                (b.budget ?? []).map(c => ({
        categoryId: c.categoryId as `0x${string}`,
        cap:        BigInt(c.cap),
      })),
      permittedRecipients:   (b.permittedRecipients ?? []) as `0x${string}`[],
      milestoneAmounts:      (b.milestoneAmounts ?? []).map(BigInt),
      milestoneDescriptions: b.milestoneDescriptions ?? [],
      collateralAmount,
      collateralAsset,
      underwriter:      underwriter as `0x${string}`,
      underwriterAmount,
    } as const;

    let calldata: string;
    try {
      calldata = encodeFunctionData({
        abi:          LoanRegistryDeployedAbi,
        functionName: "requestLoan",
        args:         [proposal],
      });
    } catch (e: unknown) {
      const msg = e instanceof Error ? e.message : String(e);
      return reply.code(400).send({ error: "Failed to encode proposal calldata", detail: msg });
    }

    return {
      to:       contracts.loanRegistry,
      calldata,
      value:    "0",
      abiVersion: "V3-deployed",
      note:     NOTE,
    };
  });
}
