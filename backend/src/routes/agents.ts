/**
 * GET /agents/:wallet          — agent identity and wallet lookup
 * GET /agents/:agentId/credit  — credit limit and repayment history
 * GET /agents/:agentId/loans   — loan IDs for an agentId (via events)
 */
import type { FastifyInstance } from "fastify";
import { contracts }             from "../config/contracts.js";
import { AgentRegistryAbi }      from "../abis/AgentRegistry.js";
import { CreditRegistryAbi }     from "../abis/CreditRegistry.js";
import { LoanRegistryAbi }       from "../abis/LoanRegistry.js";
import { readContract, getLogs } from "../lib/rpc.js";
import { validateAddress, validateUint, ValidationError, formatUnits6 } from "../lib/format.js";
import { publicClient }          from "../chain/publicClient.js";

export async function agentRoutes(app: FastifyInstance) {

  // ── GET /agents/:wallet ───────────────────────────────────────────────────
  app.get<{ Params: { wallet: string } }>("/agents/:wallet", async (req, reply) => {
    const wallet = validateAddress(req.params.wallet, "wallet");

    const agentId = await readContract({
      address: contracts.agentRegistry,
      abi:     AgentRegistryAbi,
      functionName: "walletToAgent",
      args: [wallet],
    }) as bigint;

    if (agentId === 0n) {
      return reply.code(404).send({ error: "Wallet is not registered as a Valen agent" });
    }

    const [owner, walletCount, erc8004Ref] = await Promise.all([
      readContract({ address: contracts.agentRegistry, abi: AgentRegistryAbi, functionName: "agentOwner",   args: [agentId] }) as Promise<string>,
      readContract({ address: contracts.agentRegistry, abi: AgentRegistryAbi, functionName: "walletCount",  args: [agentId] }) as Promise<bigint>,
      readContract({ address: contracts.agentRegistry, abi: AgentRegistryAbi, functionName: "erc8004Ref",   args: [agentId] }) as Promise<bigint>,
    ]);

    return {
      agentId:    agentId.toString(),
      wallet,
      owner,
      walletCount: walletCount.toString(),
      erc8004TokenId: erc8004Ref.toString(),
    };
  });

  // ── GET /agents/:agentId/credit ───────────────────────────────────────────
  app.get<{ Params: { agentId: string } }>("/agents/:agentId/credit", async (req, reply) => {
    const agentId = validateUint(req.params.agentId, "agentId");

    // creditRegistry.getLimit takes address; we need the owner address from agentRegistry
    const owner = await readContract({
      address: contracts.agentRegistry,
      abi:     AgentRegistryAbi,
      functionName: "agentOwner",
      args: [agentId],
    }) as string;

    if (!owner || owner === "0x0000000000000000000000000000000000000000") {
      return reply.code(404).send({ error: `Agent ${agentId} does not exist` });
    }

    // CreditRegistry stores credit by borrower address (the registering wallet)
    const [limit, credits] = await Promise.all([
      readContract({ address: contracts.creditRegistry, abi: CreditRegistryAbi, functionName: "getLimit",  args: [owner as `0x${string}`] }) as Promise<bigint>,
      readContract({ address: contracts.creditRegistry, abi: CreditRegistryAbi, functionName: "credits",   args: [owner as `0x${string}`] }) as Promise<readonly [bigint, bigint, bigint, bigint]>,
    ]);

    const [totalBorrowed, totalRepaid, loanCount, defaultCount] = credits;

    return {
      agentId: agentId.toString(),
      ownerAddress: owner,
      creditLimit: {
        raw:       limit.toString(),
        formatted: formatUnits6(limit),
      },
      history: {
        totalBorrowed:  { raw: totalBorrowed.toString(),  formatted: formatUnits6(totalBorrowed)  },
        totalRepaid:    { raw: totalRepaid.toString(),    formatted: formatUnits6(totalRepaid)    },
        loanCount:      loanCount.toString(),
        defaultCount:   defaultCount.toString(),
      },
    };
  });

  // ── GET /agents/:agentId/loans ────────────────────────────────────────────
  // Reads LoanRequested events filtered by agentId (indexed topic).
  // Arc Testnet: getLogs works from genesis; block ranges are not enforced.
  // Pagination: query params ?page=1&pageSize=50 (page is 1-based).
  app.get<{ Params: { agentId: string }; Querystring: { page?: string; pageSize?: string } }>(
    "/agents/:agentId/loans",
    async (req, reply) => {
      const agentId  = validateUint(req.params.agentId, "agentId");
      const page     = Math.max(1, parseInt(req.query.page ?? "1", 10));
      const pageSize = Math.min(200, Math.max(1, parseInt(req.query.pageSize ?? "50", 10)));

      // LoanRequested(uint256 indexed loanId, uint256 indexed agentId, address borrower, ...)
      // We filter by the second indexed topic (agentId).
      const logs = await getLogs({
        address: contracts.loanRegistry,
        event: {
          type: "event",
          name: "LoanRequested",
          inputs: [
            { name: "loanId",   type: "uint256", indexed: true  },
            { name: "agentId",  type: "uint256", indexed: true  },
            { name: "borrower", type: "address", indexed: false },
          ],
        },
        args: { agentId },
        fromBlock: 0n,
        toBlock:   "latest",
      });

      type LoanReqLog = { args?: { loanId?: bigint } };
      const loanIds = logs.map((l) => ((l as unknown as LoanReqLog).args?.loanId?.toString() ?? "?"));
      const total   = loanIds.length;
      const start   = (page - 1) * pageSize;
      const slice   = loanIds.slice(start, start + pageSize);

      return {
        agentId: agentId.toString(),
        total,
        page,
        pageSize,
        loanIds: slice,
        note: "Loan IDs sourced from on-chain LoanRequested events. Historical coverage from block 0.",
      };
    }
  );
}
