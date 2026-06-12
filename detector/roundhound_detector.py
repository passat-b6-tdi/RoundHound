#!/usr/bin/env python3
"""RoundHound Layer 1 — static rounding direction triage (heuristic)

flags output side fixed point values rounded DOWN against a declared `@custom:invariant` tag

usage:
    python3 detector/roundhound_detector.py [src|path/to.sol] # standalone (Slither api or fallback)
    slither . --detect roundhound-rounding-direction # as a registered Slither plugin
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# output side value names, a down rounding on any of these favours the user
OUTPUT_NAME_RE = re.compile(
    r"(amount_?out|amountout|\bout\b|\bdy\b|output|given_?out|tokensout|amounts_?out|withdraw|redeem)",
    re.IGNORECASE,
)
ROUND_DOWN = {"mulDown", "divDown"}
ROUND_UP = {"mulUp", "divUp"}
ALL_OPS = ROUND_DOWN | ROUND_UP

# invariant tags implying output must round up (stored in separator-normalised form)
PROTECTIVE_INVARIANTS = ("no-free-money", "solvency", "non-decreasing", "no-under-charge")


class Finding:
    __slots__ = ("path", "line", "op", "snippet", "severity", "reason")

    def __init__(self, path, line, op, snippet, severity, reason):
        self.path = path
        self.line = line
        self.op = op
        self.snippet = snippet.strip()
        self.severity = severity
        self.reason = reason

    def render(self) -> str:
        return (
            f" [{self.severity}] {self.path}:{self.line}  ({self.op})\n"
            f" {self.snippet}\n"
            f" > {self.reason}"
        )


def _derive_requires_round_up(source: str) -> bool:
    """true if the file declares a protective invariant (output must round up).

    Separator-insensitive: `no-free-money`, `no_free_money` and `no free money`
    all match, so the author's punctuation cannot silently downgrade a HIGH to a
    MEDIUM. Newlines are preserved so the tag and its name must stay on one line.
    """
    norm = re.sub(r"[ \t\-_]+", " ", source.lower())
    for tag in PROTECTIVE_INVARIANTS:
        tag_norm = re.sub(r"[ \t\-_]+", " ", tag.lower())  # normalise the tag too
        if re.search(r"@custom:invariant\b.*" + re.escape(tag_norm), norm):
            return True
    return False


_FILE_CACHE: dict[str, str] = {}


def _contract_file_text(contract) -> str:
    """full source file for a contract (NatSpec doc comments live above the contract node)"""
    try:
        fn = contract.source_mapping.filename.absolute
    except Exception:
        return contract.source_mapping.content or ""
    if fn not in _FILE_CACHE:
        try:
            _FILE_CACHE[fn] = Path(fn).read_text()
        except Exception:
            _FILE_CACHE[fn] = contract.source_mapping.content or ""
    return _FILE_CACHE[fn]


def _scan_source(path: Path) -> list[Finding]:
    """source level triage, works without Slither (line based)"""
    findings: list[Finding] = []
    text = path.read_text()
    requires_up = _derive_requires_round_up(text)
    lines = text.splitlines()
    for i, raw in enumerate(lines, start=1):
        line = raw.split("//", 1)[0]  # ignore line comments
        for op in ALL_OPS:
            # match e.g. mulDown(amountOut, ...)  /  FixedPoint.mulDown(out, rate)
            for m in re.finditer(rf"\b{op}\s*\(([^,)]+)", line):
                arg = m.group(1)
                is_output = bool(OUTPUT_NAME_RE.search(arg))
                if op in ROUND_DOWN and is_output:
                    sev = "HIGH" if requires_up else "MEDIUM"
                    reason = (
                        f"output side value `{arg.strip()}` is rounded DOWN, "
                        + (
                            "declared @custom:invariant requires it to round UP (favour the protocol)"
                            if requires_up
                            else "outputs should round UP to favour the protocol — verify direction"
                        )
                    )
                    findings.append(Finding(path.name, i, op, raw, sev, reason))
                elif op in ROUND_UP and is_output:
                    findings.append(
                        Finding(
                            path.name, i, op, raw, "OK",
                            f"output side value `{arg.strip()}` rounds UP (protocol favouring) — looks correct",
                        )
                    )
    return findings


def _scan_with_slither(target: str) -> list[Finding] | None:
    """IR-grounded triage via the Slither API, none if Slither unavailable"""
    try:
        from slither import Slither
        from slither.slithir.operations import LibraryCall, InternalCall
    except Exception:
        return None

    try:
        sl = Slither(target)
    except Exception as e:  # compilation / parsing problem — fall back to source scan
        print(f"[roundhound] Slither could not compile target ({e}), using source level fallback\n")
        return None

    findings: list[Finding] = []
    for contract in sl.contracts_derived:
        requires_up = _derive_requires_round_up(_contract_file_text(contract))
        for fn in contract.functions:
            for node in fn.nodes:
                for ir in node.irs:
                    name = getattr(ir, "function_name", None) or getattr(
                        getattr(ir, "function", None), "name", None
                    )
                    if name not in ALL_OPS:
                        continue
                    if not isinstance(ir, (LibraryCall, InternalCall)):
                        continue
                    args = ", ".join(str(a) for a in ir.arguments)
                    first = str(ir.arguments[0]) if ir.arguments else ""
                    is_output = bool(OUTPUT_NAME_RE.search(args))
                    line = node.source_mapping.lines[0] if node.source_mapping.lines else 0
                    fpath = Path(node.source_mapping.filename.short).name
                    snippet = (node.source_mapping.content or "").splitlines()[0] if node.source_mapping.content else f"{name}({args})"
                    if name in ROUND_DOWN and is_output:
                        sev = "HIGH" if requires_up else "MEDIUM"
                        reason = (
                            f"output side arg `{first}` rounded DOWN, "
                            + (
                                "@custom:invariant requires UP (favour protocol)"
                                if requires_up
                                else "outputs should round UP — verify"
                            )
                        )
                        findings.append(Finding(fpath, line, name, snippet, sev, reason))
                    elif name in ROUND_UP and is_output:
                        findings.append(
                            Finding(fpath, line, name, snippet, "OK", f"output side arg `{first}` rounds UP — correct")
                        )
    return findings


def main(argv: list[str]) -> int:
    target = argv[1] if len(argv) > 1 else "src"
    print("RoundHound — rounding direction triage (Layer 1, heuristic)\n")

    findings = _scan_with_slither(target)
    engine = "slither-ir"
    if findings is None:
        engine = "source-fallback"
        root = Path(target)
        files = [root] if root.is_file() else sorted(root.rglob("*.sol"))
        findings = []
        for f in files:
            findings.extend(_scan_source(f))

    print(f"[engine: {engine}]\n")
    violations = [f for f in findings if f.severity in ("HIGH", "MEDIUM")]
    oks = [f for f in findings if f.severity == "OK"]

    if violations:
        print(f"potential rounding direction violations ({len(violations)}):")
        for f in violations:
            print(f.render())
        print()
    if oks:
        print(f"output side ops that look correct ({len(oks)}):")
        for f in oks:
            print(f.render())
        print()

    if not findings:
        print("no fixed point output side rounding detecte")
    print(
        f"\nsummary: {len([f for f in violations if f.severity=='HIGH'])} HIGH, "
        f"{len([f for f in violations if f.severity=='MEDIUM'])} MEDIUM, {len(oks)} OK "
        "heuristic triage — confirm with the Layer 2 invariant suite"
    )
    # exit 1 on any HIGH so CI can gate
    return 1 if any(f.severity == "HIGH" for f in violations) else 0


# slither plugin registration
try:
    from slither.detectors.abstract_detector import AbstractDetector, DetectorClassification

    class RoundingDirectionDetector(AbstractDetector):
        ARGUMENT = "roundhound-rounding-direction"
        HELP = "output side amounts rounded down against a declared @custom:invariant"
        IMPACT = DetectorClassification.HIGH
        CONFIDENCE = DetectorClassification.MEDIUM
        WIKI = "https://github.com/passat-b6-tdi/RoundHound"
        WIKI_TITLE = "output side rounding direction"
        WIKI_DESCRIPTION = "output side value rounded down against a declared @custom:invariant, see README"
        WIKI_EXPLOIT_SCENARIO = "rounding the output down understates the user's take and leaks protocol value, see README"
        WIKI_RECOMMENDATION = "round output side amounts up (mulUp/divUp)"

        def _detect(self):
            results = []
            for contract in self.compilation_unit.contracts_derived:
                requires_up = _derive_requires_round_up(_contract_file_text(contract))
                for fn in contract.functions:
                    for node in fn.nodes:
                        for ir in node.irs:
                            nm = getattr(ir, "function_name", None) or getattr(
                                getattr(ir, "function", None), "name", None
                            )
                            if nm in ROUND_DOWN:
                                args = ", ".join(str(a) for a in getattr(ir, "arguments", []))
                                if OUTPUT_NAME_RE.search(args) and requires_up:
                                    info = [fn, f" rounds output side value DOWN ({nm}) against @custom:invariant\n"]
                                    results.append(self.generate_result(info))
            return results

    def make_plugin():
        return [RoundingDirectionDetector], []

except Exception:  # slither not installed
    pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))
