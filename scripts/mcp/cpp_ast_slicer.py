#!/usr/bin/env python3
"""
cpp_ast_slicer.py - Token-bounded C++ Symbol and AST Extraction Tool.

Extracts isolated class, struct, function, or method definitions along with
their immediate signatures and dependencies to protect agent context windows.
"""

import argparse
import json
import os
import re
import sys


def find_matching_bracket(text: str, open_idx: int) -> int:
    """Find the index of the closing bracket matching the bracket at open_idx."""
    open_char = text[open_idx]
    close_char = '}' if open_char == '{' else ')'
    depth = 0
    in_string = False
    in_char = False
    in_single_comment = False
    in_multi_comment = False

    i = open_idx
    length = len(text)
    while i < length:
        ch = text[i]
        next_ch = text[i + 1] if i + 1 < length else ''

        if in_single_comment:
            if ch == '\n':
                in_single_comment = False
        elif in_multi_comment:
            if ch == '*' and next_ch == '/':
                in_multi_comment = False
                i += 1
        elif in_string:
            if ch == '\\':
                i += 1  # Skip escape
            elif ch == '"':
                in_string = False
        elif in_char:
            if ch == '\\':
                i += 1
            elif ch == "'":
                in_char = False
        else:
            if ch == '/' and next_ch == '/':
                in_single_comment = True
                i += 1
            elif ch == '/' and next_ch == '*':
                in_multi_comment = True
                i += 1
            elif ch == '"':
                in_string = True
            elif ch == "'":
                in_char = True
            elif ch == open_char:
                depth += 1
            elif ch == close_char:
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def extract_symbol(file_path: str, symbol_name: str, max_lines: int = 150):
    if not os.path.exists(file_path):
        return {"error": f"File not found: {file_path}"}

    with open(file_path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    lines = content.splitlines(keepends=True)

    # Extract all #include statements as immediate dependencies
    includes = [line.strip() for line in lines if line.strip().startswith("#include")]

    # Search for symbol definition
    # Matches:
    # 1. class / struct / enum [class] <symbol_name>
    # 2. ReturnType [Class::]<symbol_name>(...)
    patterns = [
        # Struct / class / enum definition
        rf"(?:(?:\/\*\*[\s\S]*?\*\/|\/\/[^\n]*)\s*)*(?:template\s*<[^>]+>\s*)?(?:class|struct|enum(?:\s+class)?)\s+{re.escape(symbol_name)}\b",
        # Function or method definition
        rf"(?:(?:\/\*\*[\s\S]*?\*\/|\/\/[^\n]*)\s*)*(?:template\s*<[^>]+>\s*)?[\w:<>&*~]+\s+(?:[\w:]+::)?{re.escape(symbol_name)}\s*\([^)]*\)",
    ]

    matched_span = None
    symbol_kind = "unknown"

    for pat in patterns:
        m = re.search(pat, content)
        if m:
            matched_span = m
            if "class" in m.group(0):
                symbol_kind = "class"
            elif "struct" in m.group(0):
                symbol_kind = "struct"
            elif "enum" in m.group(0):
                symbol_kind = "enum"
            else:
                symbol_kind = "function"
            break

    if not matched_span:
        # Fallback to simple line-based regex
        for i, line in enumerate(lines):
            if symbol_name in line and not line.strip().startswith("//"):
                start_line = max(0, i - 2)
                end_line = min(len(lines), i + max_lines)
                snippet = "".join(lines[start_line:end_line])
                return {
                    "status": "PARTIAL_MATCH",
                    "file": file_path,
                    "symbol": symbol_name,
                    "kind": "fallback_snippet",
                    "start_line": start_line + 1,
                    "end_line": end_line,
                    "includes": includes[:8],
                    "code": snippet
                }
        return {"error": f"Symbol '{symbol_name}' not found in {file_path}"}

    start_pos = matched_span.start()
    # Find start line
    start_line_num = content[:start_pos].count("\n") + 1

    # Look for opening bracket '{' after match
    open_brace_idx = content.find("{", matched_span.end() - 1)
    semicolon_idx = content.find(";", matched_span.end() - 1)

    if open_brace_idx != -1 and (semicolon_idx == -1 or open_brace_idx < semicolon_idx):
        close_brace_idx = find_matching_bracket(content, open_brace_idx)
        if close_brace_idx != -1:
            end_pos = close_brace_idx + 1
            # Check for trailing semicolon (e.g. struct Foo { ... };)
            if end_pos < len(content) and content[end_pos:end_pos+2].strip().startswith(";"):
                end_pos = content.find(";", close_brace_idx) + 1
        else:
            end_pos = min(len(content), open_brace_idx + 4000)
    elif semicolon_idx != -1:
        end_pos = semicolon_idx + 1
    else:
        end_pos = matched_span.end()

    extracted_code = content[start_pos:end_pos]
    extracted_lines = extracted_code.splitlines()

    if len(extracted_lines) > max_lines:
        extracted_lines = extracted_lines[:max_lines] + [f"\n... [Truncated {len(extracted_lines) - max_lines} lines to protect context window]"]
        extracted_code = "\n".join(extracted_lines)

    end_line_num = start_line_num + len(extracted_lines) - 1

    return {
        "status": "OK",
        "file": file_path,
        "symbol": symbol_name,
        "kind": symbol_kind,
        "start_line": start_line_num,
        "end_line": end_line_num,
        "total_lines": len(extracted_lines),
        "immediate_includes": includes[:10],
        "code": extracted_code
    }


def main():
    parser = argparse.ArgumentParser(description="Extract C/C++ symbol definition with bounded context")
    parser.add_argument("--file", "-f", required=True, help="Path to C/C++ source or header file")
    parser.add_argument("--symbol", "-s", required=True, help="Class, struct, or function name to extract")
    parser.add_argument("--max-lines", "-m", type=int, default=120, help="Maximum lines to extract")
    parser.add_argument("--json", action="store_true", help="Output result as JSON")

    args = parser.parse_args()
    result = extract_symbol(args.file, args.symbol, args.max_lines)

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if "error" in result:
            print(f"[ERROR] {result['error']}", file=sys.stderr)
            sys.exit(1)
        print(f"=== {result['symbol']} ({result['kind']}) in {result['file']}:{result['start_line']}-{result['end_line']} ===")
        print(result["code"])


if __name__ == "__main__":
    main()
