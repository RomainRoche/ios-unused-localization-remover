# UnusedLocalizationRemover

A fast, concurrent macOS command-line tool written in Swift that detects and removes unused localization keys from `.strings` files.

---

## Features

- 🔍 Scans `<locale>.lproj/*.strings` files for localization keys
- 🗂 Searches `.swift`, `.m`, and `.h` source files for key usage
- 🧵 Parallel file loading and key checking via Swift Structured Concurrency (`async/await`)
- 🚫 Exclude keys by one or more regex patterns (e.g. keys starting with `NS`, `UI`, `CF`)
- 🧪 Dry-run mode — preview what would be removed without touching any files
- 📊 Summary report at the end of every run

---

## Requirements

| Requirement | Version  |
|-------------|----------|
| macOS       | 13+      |
| Swift       | 5.9+     |
| Xcode       | 15+      |

---

## Installation

### Build from source

```bash
git clone <your-repo-url>
cd UnusedLocalizationRemover
swift build -c release
```

### (Optional) Install globally

```bash
cp .build/release/localization-cleaner /usr/local/bin/
```

---

## Usage

```
OVERVIEW: Removes unused localization keys from .strings files.

USAGE: localization-cleaner [OPTIONS]

OPTIONS:
  -d, --directory <path>          Root directory to search in. (default: current directory)
  -l, --locale <locale>           Default locale to use (e.g. en, fr). (default: en)
  -e, --exclude-pattern <regex>   Regex pattern to exclude keys. Repeatable.
      --dry-run                   Only report unused keys, do not modify files.
      --verbose                   Enable verbose output.
      --concurrency <n>           Max concurrent tasks. (default: CPU core count)
  -h, --help                      Show help information.
      --version                   Show the version.
```

---

## Examples

### Basic usage (current directory, English locale)

```bash
localization-cleaner
```

### Specify a project directory and locale

```bash
localization-cleaner --directory /path/to/MyApp --locale fr
```

### Exclude keys starting with `NS`

```bash
localization-cleaner --exclude-pattern "^NS"
```

### Multiple exclusion patterns

```bash
localization-cleaner \
  --exclude-pattern "^NS" \
  --exclude-pattern "^UI" \
  --exclude-pattern "^CF" \
  --exclude-pattern "_v2$"
```

### Dry run (safe preview — no files modified)

```bash
localization-cleaner --dry-run --verbose
```

### Full example

```bash
localization-cleaner \
  --directory /path/to/MyApp \
  --locale en \
  --exclude-pattern "^NS" \
  --exclude-pattern "^UI" \
  --dry-run \
  --verbose \
  --concurrency 8
```

---

## How It Works

```
Root Directory
├── MyApp/
│   ├── en.lproj/
│   │   ├── Localizable.strings   ← keys parsed here
│   │   └── InfoPlist.strings     ← keys parsed here
│   ├── fr.lproj/                 (ignored — not the target locale)
│   ├── AppDelegate.swift         ← searched for key usage
│   ├── ViewController.m          ← searched for key usage
│   └── Header.h                  ← searched for key usage
```

| Step | Action |
|------|--------|
| 1 | Locate `<locale>.lproj/*.strings` files under the root directory |
| 2 | Parse all `"KEY" = "VALUE";` entries |
| 3 | Apply optional regex exclusion filter(s) |
| 4 | Load all `.swift` / `.m` / `.h` files concurrently |
| 5 | Check each key against source contents in parallel Swift Tasks |
| 6 | Report unused keys grouped by `.strings` file |
| 7 | Remove unused entries in-place (unless `--dry-run`) |

---

## Project Structure

```
UnusedLocalizationRemover/
├── Package.swift
├── README.md
└── Sources/
    └── main.swift
```

---

## Dependencies

- [swift-argument-parser](https://github.com/apple/swift-argument-parser) `>= 1.3.0` — CLI argument parsing

---

## License

MIT
