#!/usr/bin/env python3
"""
ASD-STE100 Simplified Technical English Linter.
Validates Markdown and documentation files against ASD-STE100 rules:
1. Zero em dashes (—) and en dashes (–).
2. Descriptive sentences <= 25 words.
3. Procedural / list sentences <= 20 words.
4. No semicolons (;).
5. Non-STE words (utilize, in order to, seamless, etc.).
"""

import sys
import os
import re

NON_STE_WORDS = {
    "utilize": "use",
    "utilizes": "uses",
    "utilized": "used",
    "utilizing": "using",
    "utilization": "use",
    "leverage": "use",
    "leveraging": "using",
    "in order to": "to",
    "terminate": "stop",
    "commence": "start",
    "initiate": "start",
    "as well as": "and",
    "seamless": "smooth / direct",
    "seamlessly": "smoothly / directly",
    "state of the art": "modern",
    "game changer": "improvement",
    "blazing fast": "fast",
    "robust": "reliable / strong",
    "due to the fact that": "because",
}

def check_file(file_path):
    if not os.path.exists(file_path):
        print(f"Error: File not found: {file_path}")
        return False

    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    violations = []
    in_code_block = False

    for line_num, raw_line in enumerate(lines, 1):
        line = raw_line.strip()

        # Handle fenced code blocks
        if line.startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        # Skip headers, horizontal rules, empty lines
        if not line or line.startswith("#") or line == "---" or line == "***":
            continue

        # Strip inline code (`...`) to avoid false positives on literal symbols and code tokens
        prose_line = re.sub(r"`[^`]+`", "CODE", line)

        # Check 1: Em dashes and en dashes in prose
        if "—" in prose_line:
            violations.append((line_num, "PUNCTUATION", "Contains em dash (—). Replace with colon, parentheses, or separate sentence."))
        if "–" in prose_line:
            violations.append((line_num, "PUNCTUATION", "Contains en dash (–). Replace with hyphen, 'to', or 'through'."))

        # Check 2: Semicolons in prose
        if ";" in prose_line and not re.search(r"&[a-zA-Z0-9#]+;", prose_line):
            violations.append((line_num, "PUNCTUATION", "Contains semicolon (;). Split into separate sentences."))

        # Check 3: Non-STE word patterns in prose
        line_lower = prose_line.lower()
        for forbidden, replacement in NON_STE_WORDS.items():
            if re.search(r"\b" + re.escape(forbidden) + r"\b", line_lower):
                violations.append((line_num, "VOCABULARY", f"Contains non-STE phrase '{forbidden}'. Use '{replacement}' instead."))

        # Check 4: Table rows
        if line.startswith("|") and line.endswith("|"):
            cells = [c.strip() for c in line.split("|")[1:-1]]
            for cell in cells:
                # Ignore divider rows
                if re.match(r"^:?-+:?$", cell):
                    continue
                words = cell.split()
                if len(words) > 25:
                    violations.append((line_num, "LENGTH", f"Table cell exceeds 25 words ({len(words)} words): '{cell[:50]}...'"))
            continue

        # Check 5: Sentence length in prose and list items
        is_list_item = bool(re.match(r"^(\*|-|\+|\d+\.)\s+", line))
        max_words = 20 if is_list_item else 25

        # Strip list markers and markdown links
        clean_line = re.sub(r"^(\*|-|\+|\d+\.)\s+", "", prose_line)
        clean_line = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", clean_line)

        # Split into sentences
        sentences = re.split(r"(?<=[.!?])\s+", clean_line)
        for s in sentences:
            s = s.strip()
            if not s or s.endswith(":"):
                continue
            words = s.split()
            if len(words) > max_words:
                rule_type = "Procedural / list" if is_list_item else "Descriptive"
                violations.append((line_num, "LENGTH", f"{rule_type} sentence exceeds {max_words} words ({len(words)} words): '{s[:60]}...'"))

    print(f"\n--- Checking: {file_path} ---")
    if not violations:
        print("  ✓ PASS: Fully compliant with ASD-STE100 rules.")
        return True
    else:
        print(f"  ✗ FAIL: Found {len(violations)} violation(s):")
        for line_num, cat, msg in violations:
            print(f"    Line {line_num:4d} [{cat:12s}]: {msg}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 lint_ste100.py <file1.md> [file2.md ...]")
        sys.exit(1)

    all_passed = True
    for f in sys.argv[1:]:
        passed = check_file(f)
        if not passed:
            all_passed = False

    sys.exit(0 if all_passed else 1)

if __name__ == "__main__":
    main()
