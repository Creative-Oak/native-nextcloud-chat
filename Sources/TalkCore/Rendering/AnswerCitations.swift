import Foundation

/// An answer about a conversation, written by the on-device model, with the messages it rests
/// on marked `[#123]` after each fact. Here the marks come out of the text and become a list of
/// message ids — each once, in the order the answer uses them.
enum AnswerCitations {
    static func parse(_ answer: String) -> (text: String, messageIDs: [Int]) {
        var ids: [Int] = []
        var text = ""
        var rest = answer[...]
        while let open = rest.range(of: "[#") {
            text += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: "]") else {
                text += rest[open.lowerBound...]
                rest = ""
                break
            }
            // "[#12, #15]" and "[#12][#15]" both.
            let inside = afterOpen[..<close]
            let found = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "#" }).compactMap { Int($0) }
            if found.isEmpty {
                text += rest[open.lowerBound...close]
            } else {
                for id in found where !ids.contains(id) { ids.append(id) }
            }
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        text += rest
        // What the marks leave behind: a space before a full stop, two spaces in a row.
        let tidied = text
            .replacingOccurrences(of: " +([.,;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tidied, ids)
    }
}
