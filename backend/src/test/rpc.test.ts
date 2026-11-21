/**
 * rpc.ts error-mapping tests — the route tests mock ../lib/rpc.js entirely,
 * so the wrapper behavior itself is covered here against a mocked publicClient.
 */
import { describe, it, expect, vi } from "vitest";

vi.mock("../chain/publicClient.js", () => ({
  publicClient: {
    readContract: vi.fn(),
    getLogs: vi.fn(),
  },
}));

import { publicClient } from "../chain/publicClient.js";
import { readContract, getLogs, RpcError } from "../lib/rpc.js";

describe("readContract error mapping", () => {
  it("maps contract reverts to 422 with the message preserved", async () => {
    vi.mocked(publicClient.readContract).mockRejectedValueOnce(
      new Error("execution reverted: UnapprovedAsset")
    );
    const err = await readContract({} as never).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect((err as RpcError).statusCode).toBe(422);
    expect((err as Error).message).toContain("UnapprovedAsset");
  });

  it("maps transport failures to 502", async () => {
    vi.mocked(publicClient.readContract).mockRejectedValueOnce(new Error("fetch failed"));
    const err = await readContract({} as never).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect((err as RpcError).statusCode).toBe(502);
  });

  it("passes successful reads through untouched", async () => {
    vi.mocked(publicClient.readContract).mockResolvedValueOnce(42n);
    await expect(readContract({} as never)).resolves.toBe(42n);
  });
});

describe("getLogs error mapping", () => {
  it("wraps failures as 502 RpcError", async () => {
    vi.mocked(publicClient.getLogs).mockRejectedValueOnce(new Error("boom"));
    const err = await getLogs({} as never).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(RpcError);
    expect((err as RpcError).statusCode).toBe(502);
  });
});
