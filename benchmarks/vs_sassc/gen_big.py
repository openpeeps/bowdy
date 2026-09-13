#!/usr/bin/env python3
"""Generate a large strict-clean fixture pair for Suite C.

Writes big.bass / big.scss with identical structure (flat utility rules,
hover nesting every 10th rule, one media block) so normalized outputs
compare equal. Every construct is --strict clean: typed values only,
declared custom props, no shorthand narrowness.

Usage: gen_big.py [--count N] [--out DIR]   (default N=2000)
"""
import argparse
import os
import sys

PALETTE = ["#0d6efd", "#333333", "#f8f9fa", "#ff0000", "#0000ff", "#008000"]


def rule_block(i, indent=""):
    c = PALETTE[i % len(PALETTE)]
    lines = [
        "%s.u-%d" % (indent, i),
        "%s  width: %dpx" % (indent, 4 + (i % 240)),
        "%s  color: %s" % (indent, c),
        "%s  background-color: var(--bg)" % indent,
        "%s  font-size: 1rem" % indent,
        "%s  margin: 8px" % (indent,),
        "%s  border-radius: 4px" % (indent,),
        "%s  z-index: %d" % (indent, i),
    ]
    if i % 10 == 0:
        lines += [
            "%s  &:hover" % indent,
            "%s    color: darken(#0d6efd, 10)" % indent,
        ]
    return lines


def gen_bass(n):
    out = [":root", "  --bg: #ffffff"]
    for i in range(n):
        out += rule_block(i)
    out += ["@media (min-width: 768px)"]
    for i in range(50):
        out += rule_block(100000 + i, indent="  ")
    # BASS media body holds rules directly; nested display rule per block:
    return "\n".join(out) + "\n"


def scss_rule_block(i, indent=""):
    c = PALETTE[i % len(PALETTE)]
    lines = [
        "%s.u-%d {" % (indent, i),
        "%s  width: %dpx;" % (indent, 4 + (i % 240)),
        "%s  color: %s;" % (indent, c),
        "%s  background-color: var(--bg);" % indent,
        "%s  font-size: 1rem;" % indent,
        "%s  margin: 8px;" % (indent,),
        "%s  border-radius: 4px;" % (indent,),
        "%s  z-index: %d;" % (indent, i),
    ]
    if i % 10 == 0:
        lines += [
            "%s  &:hover {" % indent,
            "%s    color: darken(#0d6efd, 10%%);" % indent,
            "%s  }" % indent,
        ]
    lines += ["%s}" % indent]
    return lines


def gen_scss(n):
    out = [":root {", "  --bg: #ffffff;", "}"]
    for i in range(n):
        out += scss_rule_block(i)
    out += ["@media (min-width: 768px) {"]
    for i in range(50):
        out += scss_rule_block(100000 + i, indent="  ")
    out += ["}"]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--out", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()
    with open(os.path.join(args.out, "big.bass"), "w") as f:
        f.write(gen_bass(args.count))
    with open(os.path.join(args.out, "big.scss"), "w") as f:
        f.write(gen_scss(args.count))
    print("wrote big.bass/big.scss with %d + 50 rules" % args.count)


if __name__ == "__main__":
    sys.exit(main())
