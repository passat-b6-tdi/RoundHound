# RoundHound

A developer time toolkit that catches fixed point rounding direction bugs in StableSwap style AMMs,
the class of bug behind the Balancer v2 loss (~$128M, Nov 3 2025), it catches the bug three ways, a
static detector, boundary aware invariant fuzzing, and a mutation oracle that checks the fuzzing is
adequate

All math is verified in `sim/stableswap_sim.py` (pure Python, no deps) and ported 1 to 1 to Solidity

## The bug

Balancer v2's `ComposableStablePool` EXACT_OUT swap upscales the output amount with `mulDown` (floor)
instead of `mulUp` (ceil), rounding must favor the protocol, so flooring the user's output understates
their take, the pool charges a smaller `amountIn`, and the invariant `D` ends up lower than it should,
the whole bug is one token

```solidity
// src/VulnerableStablePool.sol, the only line that differs between vulnerable and fixed
uint256 amountOutScaled =
    buggy ? FixedPoint.mulDown(amountOut, rate)   // floor, favors the user (BUG)
          : FixedPoint.mulUp(amountOut, rate);    // ceil, favors the protocol (correct)
```

The per swap error is 1 wei at every liquidity scale, it is negligible against a 10^24 reserve and
decisive against an 8 wei one, so it only becomes exploitable after liquidity is deflated to wei scale
(in the real attack, via composable BPT over ~65 iterations), this is why unit tests, single op
audits, and stock fuzzers (which never reach single digit wei balances) missed it

## What it does

| Layer                | File                                      | What                                                                                                                        |
| -------------------- | ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| 1, static detector   | `detector/roundhound_detector.py`         | flags output side values rounded `mulDown`/`divDown` when the contract declares a `@custom:invariant` requiring rounding up |
| 2, invariant fuzzing | `test/Invariants.t.sol`, `test/handlers/` | boundary aware fuzzing that drives the pool to wei scale and detects extractable value vs a correct reference               |
| 3, mutation oracle   | `mutation/run_mutations.sh`               | flips `mulUp` to `mulDown` and checks the boundary suite kills the mutant while a naive unit test does not                  |

**Model**, `src/VulnerableStablePool.sol` is a minimal 2 token StableSwap pool, the `buggy` immutable
toggles the one vulnerable line so the same test suite covers before (red) and after (green),
`correctQuoteGivenOut` is a self contained correct rounding oracle (inline ceil, independent of
`FixedPoint.mulUp`), and `src/helpers/FixedPoint.sol` and `src/helpers/StableMath.sol` are ported 1 to
1 from the sim

**Layer 1**, parses each contract and for every `mulDown`/`divDown` whose argument is an output side
value (`amountOut`, `dy`, ...) emits HIGH when the contract's `@custom:invariant` tag (eg
`no-free-money`) requires rounding up, runs as a standalone script (Slither IR analysis, with a regex
source fallback if Slither is absent) or as a registered Slither plugin, heuristic triage rather than
a verifier that points Layer 2 at suspect lines

**Layer 2**, the handler owns the pool under test plus a rounding correct reference synced to its
exact state, each step either deflates liquidity (`exitProportional`, a proportional withdraw) or runs
a there and back round trip scored differentially against the reference, which cancels curve arbitrage
and Newton iteration noise so only the rounding bug registers, three invariants assert persistent
worst case ghosts

- `prop_noFreeMoney`, worst extraction excess over pool reserve stays `< EPS`
- `prop_invariantNonDecrease`, min `D_underTest / D_reference` stays `>= 1 - D_TOL`
- `prop_shareValueMonotone`, same for BPT share value

Excess is scored relative to liquidity, not volume, because the 1 wei leak is ~0% of a 10^24 reserve
but >10% of a wei scale one, `BoundaryHandler` deflates to single digit wei and finds it,
`StockHandler` stays human scale and misses it on the same vulnerable pool, the `StdInvariant` run
targets the fixed pool by default (green), and `ROUNDHOUND_BUGGY=true` targets the vulnerable pool and
fails with a fuzzer discovered deflate then extract counterexample

**Layer 3**, mutating `FixedPoint.mulUp` to `mulDown` reintroduces the bug, the naive high liquidity
unit test still passes (mutant survives, inadequate), the boundary invariant suite fails (mutant
killed, adequate), the Layer 2 oracle is inlined precisely so this mutation cannot corrupt it too

## How to run

Prerequisites are [Foundry](https://book.getfoundry.sh/) (`forge`), Python 3, and optionally
`slither-analyzer` for the Layer 1 plugin path

```bash
# fresh clone, fetch forge-std
git submodule update --init --recursive   # or forge install

# verified math (no deps)
python3 sim/stableswap_sim.py

# full Foundry suite (all green)
forge build && forge test

# Layer 2 demos
forge test --match-test test_exploit_replay -vvv          # prints attacker profit (+4 buggy, 0 fixed)
forge test --match-test test_replay_counterexample -vvv   # human readable deflate then extract sequence
ROUNDHOUND_BUGGY=true forge test --match-test invariant_  # vulnerable pool, all 3 invariants RED

# Layer 1 static detector (standalone, regex fallback if Slither absent)
python3 detector/roundhound_detector.py src
# Layer 1 as a Slither plugin
python3 -m venv .venv && .venv/bin/pip install slither-analyzer -e detector/
.venv/bin/slither . --detect roundhound-rounding-direction

# Layer 3 mutation oracle
bash mutation/run_mutations.sh
```

## Expected output

```text
# sim, boundary [15,15], dy=3
CORRECT (mulUp)  -> amount_in=4  D_leak=0
BUGGY  (mulDown) -> amount_in=3  D_leak=1     # high liquidity, both charge 1198, no leak

# exploit replay (8 wei snapshot, there and back round trips)
VULNERABLE   token1 PROFIT = +4   (token0 fully recovered)
FIXED        token1 PROFIT =  0

# ROUNDHOUND_BUGGY=true forge test --match-test invariant_
[FAIL] invariant_noFreeMoney, invariant_invariantNonDecrease, invariant_shareValueMonotone

# mutation oracle
naive high liquidity suite , mutant SURVIVED   (inadequate)
boundary invariant suite   , mutant KILLED     (adequate)
```

## Layout

```text
sim/stableswap_sim.py            verified integer StableSwap model (source of truth)
src/helpers/FixedPoint.sol       mulDown / mulUp / divDown / divUp
src/helpers/StableMath.sol       getD / getY, ported 1 to 1 from the sim
src/VulnerableStablePool.sol     EXACT_OUT pool, bug behind a flag, self contained correct oracle
test/Parity.t.sol                proves the Solidity port matches the sim
test/Exploit.t.sol               deterministic exploit replay, prints profit
test/Invariants.t.sol            Layer 2, 3 invariants + boundary vs stock demonstrations
test/handlers/BaseHandler.sol    differential measurement + ghost accumulators
test/handlers/BoundaryHandler.sol / StockHandler.sol   finds / misses
test/NaiveUnit.t.sol             the inadequate unit test Layer 3 mutates against
detector/roundhound_detector.py  Layer 1 detector (+ Slither plugin)
mutation/run_mutations.sh        Layer 3 mutation driver
```

## Limitations

- The model is a minimal 2 token pool, deflation uses a generic proportional exit rather than BPT
  mint/burn, the BPT round trip that amplified the real attack is abstracted rather than simulated
- Layer 1 is name and heuristic based, it can over or under report, confirm hits with Layer 2
- Layer 2 needs a trustworthy correct rounding oracle to diff against, here it is the inline ceil in
  `correctQuoteGivenOut`
