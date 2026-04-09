import Foundation
import ArgumentParser

// MARK: - Supporting Types

struct ProcessResult {
    let totalKeys: Int
    let unusedKeys: [String]
    let excludedKeys: [String]
}

// MARK: - Shared Regex

/// Matches a .strings key line: `"KEY" = ...`
/// Capturing group 1 is the key. Reused by both the parser and the remover.
private let keyLineRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(
        pattern: #"^\s*"((?:[^"\\]|\\.)+)"\s*="#,
        options: [.anchorsMatchLines]
    )
}()

// MARK: - Entry Point

@main
struct LocalizationCleaner: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "localization-cleaner",
        abstract: "Removes unused localization keys from .strings files.",
        version: "1.0.0"
    )

    // MARK: - Options

    @Option(name: [.short, .long], help: "Root directory to search in.")
    var directory: String = FileManager.default.currentDirectoryPath

    @Option(name: [.short, .long], help: "Default locale to use (e.g. 'en', 'fr').")
    var locale: String = "en"

    @Option(
        name: [.short, .long],
        help: "Regex patterns to exclude keys. Can be specified multiple times (e.g. --exclude-pattern '^NS' --exclude-pattern '^UI')."
    )
    var excludePattern: [String] = []

    @Flag(name: [.short, .long], help: "Dry run: only report unused keys without deleting them.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Enable verbose output.")
    var verbose: Bool = false

    @Option(name: .long, help: "Maximum number of concurrent tasks (must be >= 1).")
    var concurrency: Int = ProcessInfo.processInfo.activeProcessorCount

    // MARK: - Run

    mutating func run() async throws {
        guard concurrency >= 1 else {
            throw ValidationError("--concurrency must be at least 1.")
        }

        let rootURL = URL(fileURLWithPath: directory).standardized

        print("Starting Localization Cleaner")
        print("   Root:        \(rootURL.path)")
        print("   Locale:      \(locale)")
        print("   Dry run:     \(dryRun)")
        print("   Concurrency: \(concurrency)")
        if !excludePattern.isEmpty {
            print("   Exclude:     \(excludePattern.joined(separator: " | "))")
        }
        print("")

        // Build combined regex from all exclude patterns.
        let excludeRegex: NSRegularExpression? = try excludePattern.isEmpty ? nil : {
            let combined = excludePattern
                .map { "(?:\($0))" }
                .joined(separator: "|")
            return try NSRegularExpression(pattern: combined)
        }()

        // 1. Find all .strings files in the target locale lproj folders.
        let stringsFiles = findStringsFiles(in: rootURL, locale: locale)

        guard !stringsFiles.isEmpty else {
            print("No .strings files found for locale '\(locale)' in \(rootURL.path)")
            return
        }

        print("Found \(stringsFiles.count) .strings file(s):")
        stringsFiles.forEach { print("   - \($0.relativePath(from: rootURL))") }
        print("")

        // 2. Find all source files (.swift, .m, .h, .xib, .storyboard, .plist).
        let sourceFiles = findSourceFiles(in: rootURL)

        guard !sourceFiles.isEmpty else {
            print("No source files (.swift, .m, .h) found in \(rootURL.path)")
            return
        }

        if verbose {
            print("Found \(sourceFiles.count) source file(s)")
            print("")
        }

        // 3. Load all source file contents in parallel.
        print("Loading source files with up to \(concurrency) concurrent tasks...")
        let sourceContents = try await loadFilesInParallel(sourceFiles, maxConcurrency: concurrency)
        print("   Done.\n")

        // 4. Process each .strings file.
        var totalUnused = 0
        var totalRemoved = 0

        for stringsFile in stringsFiles {
            let result = try await processStringsFile(
                stringsFile,
                sourceContents: sourceContents,
                excludeRegex: excludeRegex,
                rootURL: rootURL
            )
            totalUnused += result.unusedKeys.count
            if !result.unusedKeys.isEmpty {
                printReport(for: stringsFile, result: result, rootURL: rootURL)
                if !dryRun {
                    try removeUnusedKeys(from: stringsFile, keys: Set(result.unusedKeys))
                    totalRemoved += result.unusedKeys.count
                    print("   Removed \(result.unusedKeys.count) key(s) from \(stringsFile.relativePath(from: rootURL))\n")
                }
            } else {
                print("\(stringsFile.relativePath(from: rootURL)) — no unused keys found\n")
            }
        }

        // 5. Summary.
        print("─────────────────────────────────────────")
        print("Summary")
        print("   .strings files scanned : \(stringsFiles.count)")
        print("   Source files scanned   : \(sourceFiles.count)")
        print("   Unused keys found      : \(totalUnused)")
        if dryRun {
            print("   Dry run — no files were modified.")
        } else {
            print("   Keys removed           : \(totalRemoved)")
        }
        print("─────────────────────────────────────────")
    }

    // MARK: - File Discovery

    /// Returns true when the URL lives inside a directory that should be excluded
    /// from scanning (Pods, SPM .build directory, or DerivedData).
    private func isInExcludedFolder(_ url: URL, relativeTo root: URL) -> Bool {
        let rootComponents = root.standardized.pathComponents
        let urlComponents = url.standardized.pathComponents

        // Only look at components that are *below* the root to avoid false
        // positives from directory names that appear in the root path itself.
        let relativeComponents = urlComponents.dropFirst(rootComponents.count)
        let excluded: Set<String> = ["Pods", ".build", "DerivedData"]
        return relativeComponents.contains { excluded.contains($0) }
    }

    private func findStringsFiles(in root: URL, locale: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { !isInExcludedFolder($0, relativeTo: root) }
            .filter { $0.pathExtension == "strings" }
            .filter { $0.pathComponents.contains("\(locale).lproj") }
    }

    private func findSourceFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let validExtensions = Set(["swift", "m", "h", "plist", "xib", "storyboard"])

        return enumerator
            .compactMap { $0 as? URL }
            .filter { !isInExcludedFolder($0, relativeTo: root) }
            .filter { validExtensions.contains($0.pathExtension) }
    }

    // MARK: - Parallel File Loading

    private func loadFilesInParallel(_ urls: [URL], maxConcurrency: Int) async throws -> [String] {
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = [(Int, String)]()
            results.reserveCapacity(urls.count)

            var index = 0
            var inFlight = 0

            func addNext() {
                guard index < urls.count else { return }
                let i = index
                let url = urls[i]
                index += 1
                inFlight += 1
                group.addTask {
                    // Propagate read errors so we don't silently treat an
                    // unreadable file as empty (which would flag all its keys
                    // as unused).
                    do {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        return (i, content)
                    } catch {
                        fputs("Warning: could not read \(url.path): \(error.localizedDescription)\n", stderr)
                        return (i, "")
                    }
                }
            }

            // Seed initial tasks.
            while inFlight < maxConcurrency && index < urls.count {
                addNext()
            }

            // Drain and refill.
            while let (i, content) = try await group.next() {
                inFlight -= 1
                results.append((i, content))
                addNext()
            }

            // Re-order to match original URL order.
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Strings File Processing

    private func processStringsFile(
        _ url: URL,
        sourceContents: [String],
        excludeRegex: NSRegularExpression?,
        rootURL: URL
    ) async throws -> ProcessResult {
        let rawContent = try String(contentsOf: url, encoding: .utf8)
        let allKeys = parseKeys(from: rawContent)

        var excluded: [String] = []
        var candidates: [String] = []

        for key in allKeys {
            if let regex = excludeRegex {
                let range = NSRange(key.startIndex..., in: key)
                if regex.firstMatch(in: key, range: range) != nil {
                    excluded.append(key)
                    continue
                }
            }
            candidates.append(key)
        }

        if verbose {
            print("   \(url.relativePath(from: rootURL)): \(allKeys.count) keys, \(excluded.count) excluded, \(candidates.count) to check")
        }

        // Check which candidate keys are absent from all source files.
        // Search for the key wrapped in quotes to avoid substring false-positives
        // (e.g. key "title" matching source that only contains "subtitle").
        let unused: [String] = candidates.filter { key in
            let quotedKey = "\"\(key)\""
            return !sourceContents.contains { $0.contains(quotedKey) }
        }.sorted()

        return ProcessResult(
            totalKeys: allKeys.count,
            unusedKeys: unused,
            excludedKeys: excluded
        )
    }

    // MARK: - Key Parsing

    private func parseKeys(from content: String) -> [String] {
        let range = NSRange(content.startIndex..., in: content)
        let matches = keyLineRegex.matches(in: content, range: range)

        return matches.compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[keyRange])
        }
    }

    // MARK: - Key Removal

    private func removeUnusedKeys(from url: URL, keys: Set<String>) throws {
        let originalContent = try String(contentsOf: url, encoding: .utf8)
        let lines = originalContent.components(separatedBy: .newlines)

        // Detect and preserve the original trailing newline so we don't
        // corrupt the file's line ending on every run.
        let hadTrailingNewline = originalContent.hasSuffix("\n")

        var result: [String] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)

            if let match = keyLineRegex.firstMatch(in: line, range: range),
               let keyRange = Range(match.range(at: 1), in: line) {
                let key = String(line[keyRange])
                if keys.contains(key) {
                    // Skip the key line and consume an immediately following
                    // blank line to avoid leaving orphaned whitespace.
                    i += 1
                    if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                    }
                    continue
                }
            }
            result.append(line)
            i += 1
        }

        var output = result.joined(separator: "\n")
        if hadTrailingNewline && !output.hasSuffix("\n") {
            output += "\n"
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Reporting

    private func printReport(for url: URL, result: ProcessResult, rootURL: URL) {
        print("\(url.relativePath(from: rootURL))")
        print("   Total keys    : \(result.totalKeys)")
        print("   Excluded      : \(result.excludedKeys.count)")
        print("   Unused keys   : \(result.unusedKeys.count)")
        result.unusedKeys.forEach { print("      - \($0)") }
        print("")
    }
}

// MARK: - URL Helper

extension URL {
    func relativePath(from base: URL) -> String {
        let selfComponents = self.standardized.pathComponents
        let baseComponents = base.standardized.pathComponents

        let commonCount = zip(baseComponents, selfComponents)
            .prefix(while: { $0 == $1 })
            .count

        let ups = Array(repeating: "..", count: baseComponents.count - commonCount)
        let downs = selfComponents.dropFirst(commonCount)
        return (ups + downs).joined(separator: "/")
    }
}
