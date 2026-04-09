# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Run directly via swift
swift run localization-cleaner [OPTIONS]

# Run the compiled binary
.build/debug/localization-cleaner [OPTIONS]
.build/release/localization-cleaner [OPTIONS]

# Run tests (none exist currently)
swift test
```

## Architecture

This is a single-file Swift CLI tool (`Sources/main.swift`) with no tests. The entire logic lives in one `AsyncParsableCommand` struct (`LocalizationCleaner`) using `swift-argument-parser`.

**Execution flow:**
1. **File discovery** — `findStringsFiles` locates `<locale>.lproj/*.strings` under the root; `findSourceFiles` finds `.swift`, `.m`, `.h`, `.plist`, `.xib`, `.storyboard`. Both skip `Pods/`, `.build/`, and `DerivedData/` directories.
2. **Parallel loading** — `loadFilesInParallel` reads all source files concurrently using Swift structured concurrency with a bounded semaphore (`maxConcurrency`).
3. **Key detection** — `processStringsFile` parses keys via `keyLineRegex` (`^\s*"(...)"\s*=`), filters excluded keys via combined regex, then checks each candidate key against source contents by searching for `"KEY"` (quoted, to avoid substring false-positives).
4. **Removal** — `removeUnusedKeys` rewrites the `.strings` file line-by-line, dropping key lines and immediately following blank lines to avoid orphaned whitespace. Preserves original trailing newline.

**Key design decisions:**
- Usage detection is a simple `String.contains("\"key\"")` search — fast but means keys must appear literally quoted in source (dynamic key construction won't be detected).
- The shared `keyLineRegex` is a file-level `let` to avoid recompilation per file.
- `--exclude-pattern` accepts multiple values and combines them into a single `NSRegularExpression` with `|`.
