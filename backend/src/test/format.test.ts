import { describe, it, expect } from "vitest";
import {
  formatUnits6,
  validateAddress,
  validateUint,
  validateBytes32,
  loanStatusName,
  ValidationError,
} from "../lib/format.js";

describe("formatUnits6", () => {
  it("formats zero", () => expect(formatUnits6(0n)).toBe("0.000000"));
  it("formats 1 USDC (1_000_000)", () => expect(formatUnits6(1_000_000n)).toBe("1.000000"));
  it("formats 10 USDC (10_000_000)", () => expect(formatUnits6(10_000_000n)).toBe("10.000000"));
  it("formats 11 USDC (11_000_000)", () => expect(formatUnits6(11_000_000n)).toBe("11.000000"));
  it("formats fractional 1.5 USDC", () => expect(formatUnits6(1_500_000n)).toBe("1.500000"));
  it("formats 14.029180 EURC", () => expect(formatUnits6(14_029_180n)).toBe("14.029180"));
  it("handles large uint256 without float precision loss", () => {
    // 115792089237316195423570985008687907853269984665640564039457584007913129639935n
    // is uint256 max — just verify we don't throw and produce a string
    const max = 115_792_089_237_316_195_423_570_985_008_687_907_853_269_984_665_640_564_039_457_584_007_913_129_639_935n;
    const result = formatUnits6(max);
    expect(typeof result).toBe("string");
    expect(result.includes(".")).toBe(true);
  });
});

describe("loanStatusName", () => {
  it("maps 0 → Requested",       () => expect(loanStatusName(0)).toBe("Requested"));
  it("maps 4 → Active",          () => expect(loanStatusName(4)).toBe("Active"));
  it("maps 5 → Repaid",          () => expect(loanStatusName(5)).toBe("Repaid"));
  it("maps 6 → Defaulted",       () => expect(loanStatusName(6)).toBe("Defaulted"));
  it("maps unknown → Unknown(9)",() => expect(loanStatusName(9)).toBe("Unknown(9)"));
});

describe("validateAddress", () => {
  const valid = "0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f";
  it("accepts a valid address", () => {
    expect(validateAddress(valid)).toBe(valid.toLowerCase());
  });
  it("rejects too-short address", () => {
    expect(() => validateAddress("0xabc")).toThrow(ValidationError);
  });
  it("rejects missing 0x prefix", () => {
    expect(() => validateAddress("C49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f")).toThrow(ValidationError);
  });
  it("rejects non-hex characters", () => {
    expect(() => validateAddress("0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG")).toThrow(ValidationError);
  });
});

describe("validateUint", () => {
  it("parses '0'",  () => expect(validateUint("0")).toBe(0n));
  it("parses '1'",  () => expect(validateUint("1")).toBe(1n));
  it("parses large uint256", () => {
    const big = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    expect(validateUint(big)).toBe(BigInt(big));
  });
  it("rejects negative", () => {
    expect(() => validateUint("-1")).toThrow();
  });
});

describe("validateBytes32", () => {
  const valid = "0x" + "ab".repeat(32);
  it("accepts valid bytes32", () => expect(validateBytes32(valid)).toBe(valid));
  it("rejects short hash",    () => expect(() => validateBytes32("0xaabbcc")).toThrow(ValidationError));
  it("rejects no 0x prefix",  () => expect(() => validateBytes32("ab".repeat(32))).toThrow(ValidationError));
});
