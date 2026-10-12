#!/usr/bin/env bash
#
# Slither quality gate for the ChainGuard lab (Prompt 7).
#
# Two gates, both against a single Slither run over the whole Foundry project:
#
#   1. Secure gate  - every `Secure*.sol` contract must be free of
#      High/Critical findings, except the explicit per-file allowlist in
#      contracts/test/slither_golden.json (`secure_exceptions`). Those are
#      documented false positives where paying a caller-nominated recipient is
#      the contract's purpose.
#
#   2. Vulnerable gate - the set of detectors reported on each scenario's
#      `Vulnerable*.sol` contracts must exactly match the `vulnerable` map in
#      contracts/test/slither_golden.json. If a refactor removes the vulnerable
#      behaviour (or introduces a new one), the golden drifts and the gate
#      fails. Regenerate the golden with `--update`.
#
# Usage:
#   scripts/slither_check.sh            # run both gates
#   scripts/slither_check.sh --update   # regenerate slither_golden.json
#
# Requirements: python3 with `slither-analyzer`, `forge` on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS="$ROOT/contracts"
GOLDEN="$CONTRACTS/test/slither_golden.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# CI images provide python3; the Windows dev shell only provides `python`
# (the `python3` shim is a Microsoft Store stub that prints an error).
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1 \
  || ! "$PYTHON" -c "" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1 && python -c "" >/dev/null 2>&1; then
    PYTHON=python
  fi
fi
command -v "$PYTHON" >/dev/null 2>&1 || { echo "python not found" >&2; exit 1; }

cd "$CONTRACTS"

# Foundry artifacts must be fresh for the crytic-compile invocation.
forge build --silent

if [[ "${1:-}" == "--update" ]]; then
  rm -f "$WORK/slither.json"
  SLITHER_VERSION="$(slither --version 2>/dev/null || true)"
  slither . --json "$WORK/slither.json" >/dev/null 2>&1 || true
  "$PYTHON" - "$WORK/slither.json" "$GOLDEN" "$SLITHER_VERSION" <<'PY'
import json, os, sys

manifest, golden_path, slither_version = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(manifest, encoding="utf-8"))

def files_of(det):
    seen = set()
    for elem in det.get("elements", []):
        sm = elem.get("source_mapping") or {}
        if sm.get("filename_relative"):
            seen.add(sm["filename_relative"])
        for m in elem.get("members", []) or []:
            sm2 = m.get("source_mapping") or {}
            if sm2.get("filename_relative"):
                seen.add(sm2["filename_relative"])
    return seen

scenarios = {}
for sid in sorted(os.listdir("src/scenarios")):
    if not os.path.isdir(os.path.join("src/scenarios", sid)):
        continue
    vuln = {f for f in os.listdir(os.path.join("src/scenarios", sid))
            if f.endswith(".sol") and f.startswith("Vulnerable")}
    checks = set()
    for det in data["results"]["detectors"]:
        prefix = f"src/scenarios/{sid}/"
        if any(f.startswith(prefix) and os.path.basename(f) in vuln
               for f in files_of(det)):
            checks.add(det["check"])
    scenarios[sid] = sorted(checks)

golden = {
    "slither_version": slither_version.strip(),
    "vulnerable": scenarios,
    "secure_exceptions": {
        "src/scenarios/s7_sig_replay/SecureClaim.sol": ["arbitrary-send-eth"],
        "src/scenarios/s8_unchecked_call/SecurePayout.sol": ["arbitrary-send-eth"],
    },
}
with open(golden_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(golden, fh, indent=2)
    fh.write("\n")
print("golden updated: " + golden_path)
PY
  exit 0
fi

rm -f "$WORK/slither.json"
slither . --json "$WORK/slither.json" >/dev/null 2>&1 || true

"$PYTHON" - "$WORK/slither.json" "$GOLDEN" <<'PY'
import json, os, sys

manifest, golden_path = sys.argv[1], sys.argv[2]
data = json.load(open(manifest, encoding="utf-8"))
golden = json.load(open(golden_path, encoding="utf-8"))

def files_of(det):
    seen = set()
    for elem in det.get("elements", []):
        sm = elem.get("source_mapping") or {}
        if sm.get("filename_relative"):
            seen.add(sm["filename_relative"])
        for m in elem.get("members", []) or []:
            sm2 = m.get("source_mapping") or {}
            if sm2.get("filename_relative"):
                seen.add(sm2["filename_relative"])
    return seen

failures = []
secures = set()
for sid in os.listdir("src/scenarios"):
    d = os.path.join("src/scenarios", sid)
    if not os.path.isdir(d):
        continue
    for f in os.listdir(d):
        if f.endswith(".sol") and f.startswith("Secure"):
            secures.add(os.path.join(d, f))

# Gate 1: Secure contracts must have no High/Critical findings.
for det in data["results"]["detectors"]:
    if det["impact"] not in ("High", "Critical"):
        continue
    for f in sorted(files_of(det) & secures):
        allowed = golden.get("secure_exceptions", {}).get(os.path.normpath(f), [])
        if det["check"] in allowed:
            continue
        failures.append(f"Secure gate: {det['impact']} {det['check']} in {f}")

# Gate 2: Vulnerable detector sets must match the golden.
actual = {}
for sid in os.listdir("src/scenarios"):
    d = os.path.join("src/scenarios", sid)
    if not os.path.isdir(d):
        continue
    vuln = {f for f in os.listdir(d) if f.endswith(".sol") and f.startswith("Vulnerable")}
    checks = set()
    for det in data["results"]["detectors"]:
        fs = files_of(det)
        if any(os.path.basename(f) in vuln and f.startswith(f"src/scenarios/{sid}/") for f in fs):
            checks.add(det["check"])
    actual[sid] = sorted(checks)

expected = golden.get("vulnerable", {})
for sid in sorted(set(actual) | set(expected)):
    a, e = set(actual.get(sid, [])), set(expected.get(sid, []))
    if a != e:
        missing = sorted(e - a)
        extra = sorted(a - e)
        failures.append(
            f"Vulnerable gate {sid}: missing={missing} extra={extra} expected={sorted(e)}"
        )

if failures:
    print("Slither gate FAILED:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)

print("Slither gate passed: 0 High/Critical on Secure contracts; "
      "Vulnerable detector sets match the golden.")
PY