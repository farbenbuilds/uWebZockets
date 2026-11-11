#!/usr/bin/env python3
"""Maintenance-only Unicode 3.2 table generator; never invoked by a Zig build.

The first generation used Python 3.14.4's pinned unicodedata.ucd_3_2_0 and
stringprep tables. The Unicode version is asserted independently from the host
Python's current Unicode version. Generated data follows RFC 3454 and RFC 4013.

Sources:
https://www.unicode.org/Public/3.2-Update/UnicodeData-3.2.0.txt
https://www.unicode.org/Public/3.2-Update/CompositionExclusions-3.2.0.txt
https://www.rfc-editor.org/rfc/rfc3454
https://www.rfc-editor.org/rfc/rfc4013
License: https://www.unicode.org/license.txt (licenses/unicode_data.txt).

Run from any directory:
python3 misc/generate_sql_unicode.py --zig /path/to/zig-0.16.0
"""

import argparse
from pathlib import Path
import stringprep
import subprocess
import unicodedata


def codepoint_ranges(values):
    ranges = []
    for codepoint in values:
        if ranges and ranges[-1][1] + 1 == codepoint:
            ranges[-1][1] = codepoint
        else:
            ranges.append([codepoint, codepoint])
    return [(start << 32) | end for start, end in ranges]


def collect_tables():
    unicode = unicodedata.ucd_3_2_0
    assert unicode.unidata_version == "3.2.0"
    prohibited = (
        stringprep.in_table_c12,
        stringprep.in_table_c21,
        stringprep.in_table_c22,
        stringprep.in_table_c3,
        stringprep.in_table_c4,
        stringprep.in_table_c5,
        stringprep.in_table_c6,
        stringprep.in_table_c7,
        stringprep.in_table_c8,
        stringprep.in_table_c9,
    )
    predicates = (
        stringprep.in_table_b1,
        stringprep.in_table_c12,
        lambda char: any(check(char) for check in prohibited),
        stringprep.in_table_a1,
        stringprep.in_table_d1,
        stringprep.in_table_d2,
    )
    ranges = [[] for _ in predicates]
    decompositions = []
    digits = []
    combining = []
    compositions = []
    for codepoint in range(0x110000):
        char = chr(codepoint)
        for values, predicate in zip(ranges, predicates):
            if predicate(char):
                values.append(codepoint)
        if unicode.category(char) == "Cn" or 0xD800 <= codepoint <= 0xDFFF:
            continue
        normalized = unicode.normalize("NFKD", char)
        # Hangul uses the standard algorithm, avoiding 11,172 redundant entries.
        if normalized != char and not 0xAC00 <= codepoint <= 0xD7A3:
            assert len(normalized) < 256 and len(digits) < (1 << 24)
            decompositions.append(
                (codepoint << 32) | (len(normalized) << 24) | len(digits)
            )
            digits.extend(ord(scalar) for scalar in normalized)
        combining_class = unicode.combining(char)
        if combining_class:
            combining.append((codepoint << 8) | combining_class)
        decomposition = unicode.decomposition(char)
        if not decomposition or decomposition.startswith("<"):
            continue
        pair = [int(value, 16) for value in decomposition.split()]
        if len(pair) != 2:
            continue
        # NFC filters canonical composition exclusions from Unicode 3.2.
        if unicode.normalize("NFC", "".join(chr(value) for value in pair)) == char:
            compositions.append((pair[0] << 42) | (pair[1] << 21) | codepoint)

    assert (len(decompositions), len(digits), len(combining), len(compositions)) == (
        5143, 8222, 327, 1316
    )
    tables = [
        ("decompositions", "u64", decompositions,
         "Codepoint in high 32 bits; length in bits 24..31; digit offset in low 24 bits."),
        ("digits", "u21", digits, "Fully compatibility-decomposed Unicode scalar sequences."),
        ("combining", "u32", combining,
         "Codepoint in high 24 bits; canonical combining class in low 8 bits."),
        ("compositions", "u64", sorted(compositions),
         "First scalar in bits 42..62; second in bits 21..41; composed scalar in low 21 bits."),
    ]
    for name, values in zip(
        ("nothing", "spaces", "prohibited", "unassigned", "randal", "lcat"), ranges
    ):
        tables.append((name, "u64", codepoint_ranges(values),
                       "Inclusive codepoint ranges, start in high 32 bits and end in low 32 bits."))
    return tables


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig", help="Zig 0.16.0 formatter executable")
    args = parser.parse_args()
    target = Path(__file__).resolve().parents[1] / "src/sql/unicode_3_2.zig"
    with target.open("w", encoding="utf-8") as output:
        output.write("//! Generated Unicode 3.2 data for RFC3454/RFC4013, not the host Unicode version.\n")
        output.write("//! Generator: misc/generate_sql_unicode.py (maintenance only, never a build step).\n")
        output.write("//! Unicode data license: licenses/unicode_data.txt.\n\n")
        for name, zig_type, values, description in collect_tables():
            output.write(f"/// {description}\npub const {name} = [_]{zig_type}{{\n")
            for index in range(0, len(values), 8):
                output.write("    " + ", ".join(f"0x{value:x}" for value in values[index:index + 8]) + ",\n")
            output.write("};\n\n")
    subprocess.run([args.zig, "fmt", str(target)], check=True)


if __name__ == "__main__":
    main()
