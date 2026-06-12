#!/usr/bin/env bash
#
# RoundHound Layer 3 — mutation oracle
# run: bash mutation/run_mutations.sh
#
# flips `mulUp` to `mulDown` in FixedPoint and checks the naive suite SURVIVES while the boundary
# invariant suite is KILLED

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/src/helpers/FixedPoint.sol"
BACKUP="$TARGET.orig"

# mutate mulUp to round down (reintroduce the bug)
MUTANT_DESC="FixedPoint.mulUp: round-up > round down (mulUp > mulDown)"
SED_EXPR='s|return ((product - 1) / ONE) + 1;|return product / ONE; /* MUTANT: mulUp>mulDown */|'

cleanup() {
  if [ -f "$BACKUP" ]; then mv -f "$BACKUP" "$TARGET"; fi
}
trap cleanup EXIT INT TERM

echo "=================================================================="
echo " RoundHound mutation oracle"
echo " Mutant: $MUTANT_DESC"
echo "=================================================================="

# baseline: everything green on the unmutated tree
echo
echo "[0/3] Baseline (no mutation): full suite must be GREEN ..."
if forge test >/dev/null 2>&1; then
  echo " baseline: PASS"
else
  echo " baseline: FAIL — fix the suite before mutating." ; exit 1
fi

# apply mutation
cp "$TARGET" "$BACKUP"
sed -i.bak "$SED_EXPR" "$TARGET" && rm -f "$TARGET.bak"
if ! grep -q "MUTANT: mulUp>mulDown" "$TARGET"; then
  echo "ERROR: mutation did not apply (source drifted?)." ; exit 1
fi
echo
echo "[1/3] Mutation applied to FixedPoint.mulUp."

# naive suite: expect SURVIVE (tests still pass)
echo
echo "[2/3] NAIVE high liquidity unit test vs mutant (expect SURVIVE = tests PASS) ..."
if forge test --match-contract NaiveHighLiquidityTest >/dev/null 2>&1; then
  NAIVE="SURVIVED"
  echo " > mutant SURVIVED the naive suite  (naive tests are INADEQUATE)"
else
  NAIVE="KILLED"
  echo " > mutant unexpectedly killed by naive suite"
fi

# boundary invariant suite: expect KILLED (tests fail)
echo
echo "[3/3] BOUNDARY invariant suite vs mutant (expect KILLED = tests FAIL) ..."
if forge test --match-test invariant_ >/dev/null 2>&1; then
  BOUNDARY="SURVIVED"
  echo " > mutant SURVIVED the boundary suite (unexpected)"
else
  BOUNDARY="KILLED"
  echo " > mutant KILLED by the boundary suite  (boundary invariants are ADEQUATE)"
fi

echo
echo "=================================================================="
echo " RESULT"
echo " naive high-liquidity suite : mutant $NAIVE"
echo " boundary invariant suite : mutant $BOUNDARY"
echo "=================================================================="
if [ "$NAIVE" = "SURVIVED" ] && [ "$BOUNDARY" = "KILLED" ]; then
  echo " PASS: the boundary suite kills a rounding mutant that naive unit tests miss."
  exit 0
else
  echo " UNEXPECTED: see output above."
  exit 1
fi

# optional: slither-mutate can drive the same campaign
#     slither-mutate src/helpers/FixedPoint.sol --test-cmd 'forge test --match-test invariant_'
