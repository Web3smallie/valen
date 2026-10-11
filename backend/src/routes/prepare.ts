/**
 * POST /loans/prepare
 *
 * Validates a LoanProposal and returns the ABI-encoded calldata the agent must
 * sign and broadcast itself. The backend NEVER signs or broadcasts.
 *
 * ABI versioning
 * ──────────────
 * DEPLOYED (current): LoanRegistryDeployedAbi — 15-field LoanProposal, selector
 *   matching the V3 implementation currently on Arc Testnet proxy
 *   0x253B68c7a2D646561387Dc0958A6C176a30a6f8d.
 *   directDisbursement is NOT a valid field and is rejected if supplied.
 *
 * UPGRADE (pending): LoanRegistryAbi — 16-field LoanProposal, adds
 *   directDisbursement as the final bool. Will be active after Batches 4+5
 *   deploy the new LoanRegistry and LoanVault implementations.
 *
 * This endpoint targets the DEPLOYED ABI. After the upgrade is confirmed
 * on-chain, switch the import below from LoanRegistryDeployedAbi to
 * LoanRegistryAbi and remove the directDisbursement rejection guard.
 */
import type { FastifyInstance } from "fastify";
import { encodeFunctionData, isAddress } from "viem";
import { contracts } from "../config/contracts.js";
import { LoanRegistryDeployedAbi } from "../abis/LoanRegistryDeployed.js";
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

export async function prepareRoutes(app: FastifyInstance) {

  app.post<{ Body: ProposalBody }>("/loans/prepare", async (req, reply) => {
    const b = req.body ?? {};
    const errs: string[] = [];

    // ── Reject directDisbursement — not in deployed contract ─────────────────
    if (b.directDisbursement !== undefined) {
      return reply.code(400).send({
        error: "directDisbursement is not supported by the currently deployed LoanRegistry (V3). " +
               "Remove this field. It will become available after the V4 upgrade is deployed on-chain.",
      });
    }

    // ── Validate required fields ──────────────────────────────────────────────
    if (b.agentId == null || b.agentId === "") errs.push("agentId is required");
    if (!isAddress(b.creditWallet ?? ""))        errs.push("creditWallet must be a valid address");

    let principal = 0n;
    try {
      principal = BigInt(b.principal ?? "");
      if (principal <= 0n) errs.push("principal must be > 0");
    } catch { errs.push("principal must be a valid integer string"); }

    if (!b.repaymentRateBps || b.repaymentRateBps <= 0)
      errs.push("repaymentRateBps must be a positive integer");

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

    if (!Array.isArray(b.permittedRecipients) || b.permittedRecipients.length === 0)
      errs.push("permittedRecipients must be a non-empty array");

    for (const r of (b.permittedRecipients ?? [])) {
      if (!isAddress(r)) errs.push(`permittedRecipients: "${r}" is not a valid address`);
    }

    if (!Array.isArray(b.milestoneAmounts) || b.milestoneAmounts.length === 0)
      errs.push("milestoneAmounts must be a non-empty array");

    if (!Array.isArray(b.milestoneDescriptions) ||
        b.milestoneDescriptions.length !== (b.milestoneAmounts?.length ?? 0))
      errs.push("milestoneDescriptions length must match milestoneAmounts length");

    if (!isAddress(b.collateralAsset ?? ""))
      errs.push("collateralAsset must be a valid address");

    if (errs.length > 0) {
      return reply.code(400).send({ error: "Validation failed", details: errs });
    }

    const collateralAsset  = b.collateralAsset as `0x${string}`;
    const collateralAmount = BigInt(b.collateralAmount ?? "0");

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

    // ── Encode calldata using the DEPLOYED 15-field ABI ───────────────────────
    const proposal = {
      agentId:               BigInt(b.agentId),
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
      underwriter:      (b.underwriter ?? "0x0000000000000000000000000000000000000000") as `0x${string}`,
      underwriterAmount: BigInt(b.underwriterAmount ?? "0"),
    } as const;

    const calldata = encodeFunctionData({
      abi:          LoanRegistryDeployedAbi,
      functionName: "requestLoan",
      args:         [proposal],
    });

    return {
      to:       contracts.loanRegistry,
      calldata,
      value:    "0",
      abiVersion: "V3-deployed",
      note:     "Sign and broadcast this transaction with the agent's own wallet. " +
                "The backend does not sign or submit transactions.",
    };
  });
}
