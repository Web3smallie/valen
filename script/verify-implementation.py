#!/usr/bin/env python3
"""
Read-only check: does the runtime code deployed at <address> equal the runtime
code produced by `FOUNDRY_PROFILE=upgrade forge build` for <Contract>?

  python3 script/verify-implementation.py LoanRegistry 0xNewImpl
  python3 script/verify-implementation.py LoanRegistry 0xNewImpl --artifacts out/upgrade --rpc https://rpc.testnet.arc.io
  python3 script/verify-implementation.py LoanRegistry --proxy 0x253B68c7a2D646561387Dc0958A6C176a30a6f8d   # reads the impl slot first

Sends no transaction and needs no key: it only calls eth_getCode / eth_getStorageAt.

Normalisation (both sides): the trailing CBOR metadata hash is stripped, and every
byte range listed in the artifact's `immutableReferences` is zeroed (UUPSUpgradeable
embeds the implementation's own address as an immutable).

Exit code 0 = MATCH, 1 = DIFFERENT, 2 = could not determine.
"""
import argparse, json, subprocess, sys, time

IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"


def rpc(url, method, params):
    for attempt in range(8):
        out = subprocess.run(
            ["curl", "-s", "-m", "60", "-X", "POST", "-H", "Content-Type: application/json",
             "--data", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}), url],
            capture_output=True, text=True).stdout
        try:
            r = json.loads(out)
        except Exception:
            r = {"error": {"message": out[:200]}}
        if "error" in r and r["error"].get("code") == -32005:  # rate limited
            time.sleep(attempt + 1)
            continue
        return r
    return r


def strip_metadata(b: bytes) -> bytes:
    n = int.from_bytes(b[-2:], "big")
    return b[: -(n + 2)] if 0 < n + 2 < len(b) else b


def zero_ranges(b: bytes, refs: dict) -> bytes:
    a = bytearray(b)
    for ranges in refs.values():
        for r in ranges:
            a[r["start"]: r["start"] + r["length"]] = b"\x00" * r["length"]
    return bytes(a)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("contract")
    ap.add_argument("address", nargs="?")
    ap.add_argument("--proxy")
    ap.add_argument("--artifacts", default="out/upgrade")
    ap.add_argument("--rpc", default="https://rpc.testnet.arc.io")
    a = ap.parse_args()

    addr = a.address
    if a.proxy:
        r = rpc(a.rpc, "eth_getStorageAt", [a.proxy, IMPL_SLOT, "latest"])
        if "result" not in r:
            print("could not read the implementation slot:", r); sys.exit(2)
        addr = "0x" + r["result"][-40:]
        print(f"implementation slot of {a.proxy} = {addr}")
    if not addr:
        print("give an implementation address or --proxy"); sys.exit(2)

    art = json.load(open(f"{a.artifacts}/{a.contract}.sol/{a.contract}.json"))
    local = bytes.fromhex(art["deployedBytecode"]["object"][2:])
    refs = art["deployedBytecode"].get("immutableReferences", {})

    r = rpc(a.rpc, "eth_getCode", [addr, "latest"])
    if "result" not in r or r["result"] in ("0x", None):
        print(f"no code at {addr} ({r})"); sys.exit(2)
    chain = bytes.fromhex(r["result"][2:])

    c = zero_ranges(strip_metadata(chain), refs)
    l = zero_ranges(strip_metadata(local), refs)
    ok = c == l
    print(f"{a.contract} @ {addr}")
    print(f"  deployed runtime : {len(chain)} bytes   local artifact ({a.artifacts}): {len(local)} bytes")
    print(f"  immutable ranges zeroed: {sum(len(v) for v in refs.values())}   metadata stripped on both sides")
    print("  RESULT:", "MATCH" if ok else "DIFFERENT")
    sys.exit(0 if ok else 1)


main()
