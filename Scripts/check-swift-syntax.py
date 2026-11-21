#!/usr/bin/env python3
"""Check Swift sources for truncated text and unbalanced delimiters.

This is a consistency check for the many Swift files edited on a device, not a
full Swift grammar check. With tree-sitter installed it uses the real grammar;
otherwise it scans strings, comments, brackets and raw-string delimiters and
reports `mode: token-fallback` so a caller never mistakes it for a full parse.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    Language = None
    Parser = None
    tree_sitter_swift = None

LIMITS = {
    "max_files": 2000,
    "max_bytes_per_file": 2 * 1024 * 1024,
    "max_errors": 100,
    "max_examples": 5,
}
MAX_DEPTH = 32


class SyntaxProbeError(Exception):
    pass


def parse_args():
    parser = argparse.ArgumentParser(
        description="Check Swift syntax without a compiler."
    )
    parser.add_argument("--path", required=True, help="file or directory to scan")
    parser.add_argument(
        "--glob", default="*.swift", help="file name pattern when path is a directory"
    )
    parser.add_argument(
        "--exclude", action="append", default=[], help="directory name to skip"
    )
    parser.add_argument(
        "--max-files", type=int, default=LIMITS["max_files"], help="maximum files read"
    )
    parser.add_argument(
        "--max-bytes-per-file",
        type=int,
        default=LIMITS["max_bytes_per_file"],
        help="skip a source larger than this",
    )
    parser.add_argument("--json", action="store_true", help="JSON output")
    return parser.parse_args()


def walk(path, pattern, excludes, max_files):
    """Yield Swift files below path, newest-independent, skipping excludes."""
    if os.path.isfile(path):
        yield path
        return
    if not os.path.isdir(path):
        raise SyntaxProbeError("path is neither a file nor a directory")

    regex = re.compile(fnmatch_translate(pattern))
    seen = 0
    pending = [(os.path.realpath(path), 0)]
    while pending:
        current, depth = pending.pop()
        if depth > MAX_DEPTH:
            continue
        try:
            entries = sorted(os.scandir(current), key=lambda e: e.name)
        except OSError as exc:
            raise SyntaxProbeError("cannot read {}: {}".format(current, exc))
        for entry in entries:
            if entry.is_dir(follow_symlinks=False):
                if entry.name in excludes or entry.name.startswith("."):
                    continue
                pending.append((entry.path, depth + 1))
            elif entry.is_file(follow_symlinks=False) and regex.match(entry.name):
                seen += 1
                if seen > max_files:
                    raise SyntaxProbeError(
                        "too many files (limit {})".format(max_files)
                    )
                yield entry.path


def fnmatch_translate(pattern):
    """Translate a simple * / ? file-name glob to a regular expression."""
    out = ["^"]
    for char in pattern:
        if char == "*":
            out.append(".*")
        elif char == "?":
            out.append(".")
        else:
            out.append(re.escape(char))
    out.append("$")
    return "".join(out)


def token_scan(source):
    """A lightweight delimiter/string/comment balance check.

    Used only when tree-sitter is not installed. It catches truncated files and
    unbalanced braces, brackets and parentheses, but cannot catch every Swift
    grammar error; the result says which mode produced it.
    """
    i = 0
    n = len(source)
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    line = 1
    column = 1

    def advance(text):
        nonlocal line, column
        for char in text:
            if char == "\n":
                line += 1
                column = 1
            else:
                column += 1

    while i < n:
        char = source[i]
        if char == "\n":
            i += 1
            advance("\n")
            continue
        if char == "/" and i + 1 < n and source[i + 1] == "/":
            end = source.find("\n", i)
            if end < 0:
                end = n
            advance(source[i:end])
            i = end
            continue
        if char == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            if end < 0:
                return (line, column, "unterminated block comment")
            advance(source[i : end + 2])
            i = end + 2
            continue
        if char == "#" or source.startswith('"""', i):
            # Swift raw / multiline strings. The closing delimiter mirrors the
            # opener: #"""..."""#, """#...#""", #"..."# or """...""". Searching
            # for a short delimiter such as "# inside raw JSON closes it far
            # too early, so match the whole opener instead.
            leading = 0
            while i + leading < n and source[i + leading] == "#":
                leading += 1
            quote_at = i + leading
            if quote_at < n and source[quote_at] == '"':
                multiline = source.startswith('"""', quote_at)
                quote_len = 3 if multiline else 1
                trailing = 0
                if multiline and leading == 0:
                    while (
                        quote_at + quote_len + trailing < n
                        and source[quote_at + quote_len + trailing] == "#"
                    ):
                        trailing += 1
                start_line, start_column = line, column
                closing = (
                    ("#" * trailing + '"""' + "#" * leading)
                    if multiline
                    else ('"' + "#" * leading)
                )
                end = source.find(closing, quote_at + quote_len)
                if end < 0:
                    return (start_line, start_column, "unterminated raw string")
                advance(source[i : end + len(closing)])
                i = end + len(closing)
                continue
            if leading:
                # A bare # (#if, #keyPath, #selector) is an ordinary token.
                advance(source[i : i + leading])
                i += leading
                continue
        if char == '"':
            start_line, start_column = line, column
            i += 1
            advance('"')
            closed = False
            while i < n:
                if source[i] == "\\":
                    if i + 1 >= n:
                        break
                    advance(source[i : i + 2])
                    i += 2
                    continue
                if source[i] == '"':
                    i += 1
                    advance('"')
                    closed = True
                    break
                advance(source[i])
                i += 1
            if not closed:
                return (start_line, start_column, "unterminated string")
            continue
        if char in "([{":
            stack.append((char, line, column))
        elif char in ")]}":
            if not stack or stack[-1][0] != pairs[char]:
                return (line, column, "unexpected '{}'".format(char))
            stack.pop()
        i += 1
        advance(char)
    if stack:
        opener, error_line, error_column = stack[-1]
        return (error_line, error_column, "unclosed '{}'".format(opener))
    return None


def tree_scan(source_bytes):
    language = Language(tree_sitter_swift.language())
    parser = Parser(language)
    tree = parser.parse(source_bytes)
    node = tree.root_node
    if node.has_error:
        def walk_error(current):
            if current.type == "ERROR" or current.is_missing:
                return current
            for child in current.children:
                found = walk_error(child)
                if found is not None:
                    return found
            return None

        error = walk_error(node)
        if error is None:
            return None
        point = error.start_point
        return (point.row + 1, point.column + 1, "syntax error")
    return None


def main():
    args = parse_args()
    mode = "tree-sitter" if Parser is not None else "token-fallback"
    result = {
        "mode": mode,
        "scanned": 0,
        "skipped": [],
        "nodes": 0,
        "errors": [],
        "truncated": False,
    }
    try:
        for path in walk(args.path, args.glob, set(args.exclude), args.max_files):
            try:
                with open(path, "rb") as handle:
                    data = handle.read(args.max_bytes_per_file + 1)
            except OSError as exc:
                result["skipped"].append({"path": path, "reason": str(exc)})
                continue
            if len(data) > args.max_bytes_per_file:
                result["skipped"].append({"path": path, "reason": "file too large"})
                continue
            result["scanned"] += 1
            if mode == "tree-sitter":
                problem = tree_scan(data)
                # Count the roots parsed; a tree-walk is cheap on these sources.
                language = Language(tree_sitter_swift.language())
                parser = Parser(language)
                result["nodes"] += len(parser.parse(data).root_node.children)
            else:
                source = data.decode("utf-8", errors="replace")
                problem = token_scan(source)
                result["nodes"] += sum(1 for line in source.splitlines() if line.strip())
            if problem is not None:
                if len(result["errors"]) >= LIMITS["max_errors"]:
                    result["truncated"] = True
                    break
                line, column, message = problem
                result["errors"].append(
                    {
                        "path": path,
                        "line": line,
                        "column": column,
                        "message": message,
                    }
                )
    except SyntaxProbeError as exc:
        result["error"] = str(exc)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print("mode: {}".format(result["mode"]))
        print("scanned: {}".format(result["scanned"]))
        print("nodes: {}".format(result["nodes"]))
        if result.get("error"):
            print("error: {}".format(result["error"]))
        for skip in result["skipped"][: LIMITS["max_examples"]]:
            print("skipped: {} ({})".format(skip["path"], skip["reason"]))
        for error in result["errors"][: LIMITS["max_errors"]]:
            print(
                "error: {}:{}:{} {}".format(
                    error["path"], error["line"], error["column"], error["message"]
                )
            )
        if result["truncated"]:
            print("errors truncated at {}".format(LIMITS["max_errors"]))
    return 1 if result["errors"] or result.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
