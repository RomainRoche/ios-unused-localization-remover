import Foundation
import ArgumentParser

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

    @Option(name: .long, help: "Maximum number of concurrent tasks.")
    var concurrency: Int = ProcessInfo.processInfo.activeProcessorCount

    // MARK: - Run

    mutating func run() async throws {
        let rootURL = URL(fileURLWithPath: directory).standardized

        print("🔍 Starting Localization Cleaner")
        print("   Root:        \(rootURL.path)")
        print("   Locale:      \(locale)")
        print("   Dry run:     \(dryRun)")
        print("   Concurrency: \(concurrency)")
        if !excludePattern.isEmpty {
            print("   Exclude:     \(excludePattern.joined(separator: " | "))")
        }
        print("")

        // Build combined regex from all patterns
        let excludeRegex: NSRegularExpression? = excludePattern.isEmpty ? nil : try {
            let combined = excludePattern
                .map { "(?:\($0))" }
                .joined(separator: "|")
            return try NSRegularExpression(pattern: combined)
        }()

        // 1. Find all .strings files in the target locale lproj folders
        let stringsFiles = findStringsFiles(in: rootURL, locale: locale)

        guard !stringsFiles.isEmpty else {
            print("⚠️  No .strings files found for locale '\(locale)' in \(rootURL.path)")
            return
        }

        print("📄 Found \(stringsFiles.count) .strings file(s):")
        stringsFiles.forEach { print("   - \($0.relativePath(from: rootURL))") }
        print("")

        // 2. Find all source files (.swift, .m, .h)
        let sourceFiles = findSourceFiles(in: rootURL)

        guard !sourceFiles.isEmpty else {
            print("⚠️  No source files (.swift, .m, .h) found in \(rootURL.path)")
            return
        }

        if verbose {
            print("🗂  Found \(sourceFiles.count) source file(s)")
            print("")
        }

        // 3. Load all source file contents in parallel
        print("⚡️ Loading source files with up to \(concurrency) concurrent tasks…")
        let sourceContents = try await loadFilesInParallel(sourceFiles, maxConcurrency: concurrency)
        print("   Done.\n")

        // 4. Process each .strings file
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
                    print("   ✅ Removed \(result.unusedKeys.count) key(s) from \(stringsFile.relativePath(from: rootURL))\n")
                }
            } else {
                print("✅ \(stringsFile.relativePath(from: rootURL)) — no unused keys found\n")
            }
        }

        // 5. Summary
        print("─────────────────────────────────────────")
        print("📊 Summary")
        print("   .strings files scanned : \(stringsFiles.count)")
        print("   Source files scanned   : \(sourceFiles.count)")
        print("   Unused keys found      : \(totalUnused)")
        if dryRun {
            print("   ℹ️  Dry run — no files were modified.")
        } else {
            print("   Keys removed           : \(totalRemoved)")
        }
        print("─────────────────────────────────────────")
    }

    // MARK: - File Discovery

    // MARK: - Helpers (File Discovery)

    private func isInPodsFolder(_ url: URL) -> Bool {
        url.pathComponents.contains("Pods")
    }

    private func findStringsFiles(in root: URL, locale: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { !isInPodsFolder($0) }
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
            .filter { !isInPodsFolder($0) }          // ← exclude Pods
            .filter { validExtensions.contains($0.pathExtension) }
    }


    // MARK: - Parallel File Loading

    func loadFilesInParallel(_ urls: [URL], maxConcurrency: Int) async throws -> [String] {
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
                    let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    return (i, content)
                }
            }

            // Seed initial tasks
            while inFlight < maxConcurrency && index < urls.count {
                addNext()
            }

            // Drain and refill
            while let (i, content) = try await group.next() {
                inFlight -= 1
                results.append((i, content))
                addNext()
            }

            // Re-order to match original URL order
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - Strings File Parsing

    struct ProcessResult {
        let totalKeys: Int
        let unusedKeys: [String]
        let excludedKeys: [String]
    }

    func processStringsFile(
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

        // Check each candidate key in parallel across source contents
        let unused = try await withThrowingTaskGroup(of: (String, Bool).self) { group in
            var semaphoreCount = 0

            for key in candidates {
                group.addTask {
                    let isUsed = sourceContents.contains { content in
                        content.contains(key)
                    }
                    return (key, !isUsed)
                }
                semaphoreCount += 1
            }

            var unusedKeys: [String] = []
            for try await (key, isUnused) in group {
                if isUnused { unusedKeys.append(key) }
            }
            return unusedKeys.sorted()
        }

        return ProcessResult(
            totalKeys: allKeys.count,
            unusedKeys: unused,
            excludedKeys: excluded
        )
    }

    // MARK: - Key Parsing

    func parseKeys(from content: String) -> [String] {
        // Matches: "KEY" = "VALUE";
        // Also handles keys with escape sequences
        let pattern = #"^\s*"((?:[^"\\]|\\.)+)"\s*="#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return [] }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: range)

        return matches.compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: content) else { return nil }
            return String(content[keyRange])
        }
    }

    // MARK: - Key Removal

    func removeUnusedKeys(from url: URL, keys: Set<String>) throws {
        var content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        var result: [String] = []
        var i = 0

        // Regex to detect a key line: "KEY" = "VALUE";
        let keyPattern = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)+)"\s*="#)

        while i < lines.count {
            let line = lines[i]
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            if let match = keyPattern.firstMatch(in: line, range: range),
               let keyRange = Range(match.range(at: 1), in: line) {
                let key = String(line[keyRange])
                if keys.contains(key) {
                    // Skip this line (and remove trailing blank line if present)
                    i += 1
                    // Optionally eat the blank line after the entry
                    if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                    }
                    continue
                }
            }
            result.append(line)
            i += 1
        }

        content = result.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Reporting

    func printReport(for url: URL, result: ProcessResult, rootURL: URL) {
        print("⚠️  \(url.relativePath(from: rootURL))")
        print("   Total keys    : \(result.totalKeys)")
        print("   Excluded      : \(result.excludedKeys.count)")
        print("   Unused keys   : \(result.unusedKeys.count)")
        result.unusedKeys.forEach { print("      🗑  \($0)") }
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
