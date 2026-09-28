// Reports what a string catalog is missing: strings the build found that the catalog doesn't
// have yet, and strings not translated into every language the catalog has.
// Run by Tools/check_translations.sh; see there.
//
//   swift check_translations.swift <catalog> [<synced copy of the catalog>]
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let catalogPath = arguments.first else {
    FileHandle.standardError.write(Data("usage: check_translations.swift <catalog> [<synced catalog>]\n".utf8))
    exit(2)
}
let syncedPath = arguments.dropFirst().first

func load(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        FileHandle.standardError.write(Data("Couldn’t read \(path)\n".utf8))
        exit(2)
    }
    return object
}

/// Every `stringUnit` state under a localization, plural and device variations included, and
/// the state of a `stringSet` (the alternatives of a Siri phrase).
func states(in node: Any) -> [String] {
    guard let node = node as? [String: Any] else { return [] }
    var found: [String] = []
    for (key, value) in node {
        if key == "stringUnit" || key == "stringSet", let unit = value as? [String: Any] {
            found.append(unit["state"] as? String ?? "")
        } else {
            found += states(in: value)
        }
    }
    return found
}

let catalog = load(catalogPath)
let name = (catalogPath as NSString).lastPathComponent
let source = catalog["sourceLanguage"] as? String ?? "en"
let strings = catalog["strings"] as? [String: [String: Any]] ?? [:]
let synced = syncedPath.map { load($0)["strings"] as? [String: [String: Any]] ?? [:] } ?? strings

// The languages the catalog is translated into: any one string in a language asks for all.
var languages = Set<String>()
for entry in strings.values {
    for language in (entry["localizations"] as? [String: Any] ?? [:]).keys where language != source {
        languages.insert(language)
    }
}

var problems = 0
func report(_ line: String) {
    problems += 1
    print("  \(line)")
}

let unknown = synced.keys.filter { strings[$0] == nil }.sorted()
if !unknown.isEmpty {
    print("\(name): \(unknown.count) string(s) the build uses aren’t in the catalog yet:")
    unknown.forEach { report("“\($0)”") }
}

for language in languages.sorted() {
    var missing: [String] = []
    for (key, entry) in synced where strings[key] != nil {
        if entry["extractionState"] as? String == "stale" { continue }
        if entry["shouldTranslate"] as? Bool == false { continue }
        // A string of placeholders, symbols and punctuation has nothing to translate.
        if key.replacingOccurrences(of: #"%(\d+\$)?(\.\d+)?(lld|ld|d|@|lf|f)"#, with: "", options: .regularExpression)
            .rangeOfCharacter(from: .letters) == nil { continue }
        let localization = (strings[key]?["localizations"] as? [String: Any])?[language]
        let found = localization.map(states(in:)) ?? []
        if found.isEmpty || found.contains(where: { $0 != "translated" }) {
            missing.append(key)
        }
    }
    if !missing.isEmpty {
        print("\(name): \(missing.count) string(s) not translated into \(language) (or marked for review):")
        missing.sorted().forEach { report("“\($0)”") }
    }
}

let stale = synced.filter { strings[$0.key] != nil && $0.value["extractionState"] as? String == "stale" }.keys.sorted()
if !stale.isEmpty {
    // Not a failure: stale strings are harmless, just no longer used.
    print("\(name): \(stale.count) string(s) no longer used (stale), safe to delete in Xcode:")
    stale.forEach { print("  “\($0)”") }
}

exit(problems == 0 ? 0 : 1)
