import Foundation

/// One line of Live Captions: what one person said, in one go.
struct CaptionLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// Whose voice it is: a signaling session, or this Mac's own microphone.
    let speakerID: String
    var speaker: String
    /// Words the model has settled on.
    var settled: String
    /// Words it is still hearing, which the next result may change.
    var pending: String
    var updatedAt: Date
    /// Done: whatever they say next starts a new line.
    var isClosed = false

    var text: String {
        [settled, pending].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What everyone in a call has said lately, as Live Captions shows it: a line per person per
/// stretch of talking, the newest at the bottom, gone a few seconds after they stop.
///
/// A speech model reports as it hears: a *pending* result that each next one replaces, until
/// it settles on the words and says so in a *final* one. A line keeps the settled words and
/// shows the pending ones after them; it ends when its speaker has been quiet for a moment,
/// or once it is long enough to read as a paragraph. People talking over each other each
/// keep their own line.
struct CaptionLog: Equatable, Sendable {
    /// Quiet for this long after their words settled, and what they say next is a new line.
    var pause: TimeInterval = 2.5
    /// Settled text this long ends the line.
    var lineLength = 160
    /// A line nobody has added to for this long is off the screen.
    var linger: TimeInterval = 7
    /// How many lines are on screen at once.
    var shown = 3
    /// How many are kept at all — the whole call's worth, for its transcript and summary.
    var kept = 5_000

    private(set) var lines: [CaptionLine] = []
    private var nextID = 0

    init() {}

    /// A result from the model listening to one voice.
    mutating func receive(_ text: String, isFinal: Bool, from speakerID: String, named speaker: String, at now: Date = Date()) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = openLine(for: speakerID, at: now) {
            if isFinal {
                if !text.isEmpty {
                    lines[index].settled = lines[index].settled.isEmpty ? text : lines[index].settled + " " + text
                }
                lines[index].pending = ""
                if lines[index].settled.count >= lineLength { lines[index].isClosed = true }
            } else {
                lines[index].pending = text
            }
            lines[index].speaker = speaker
            lines[index].updatedAt = now
            return
        }
        guard !text.isEmpty else { return }
        lines.append(CaptionLine(
            id: nextID,
            speakerID: speakerID,
            speaker: speaker,
            settled: isFinal ? text : "",
            pending: isFinal ? "" : text,
            updatedAt: now,
            isClosed: isFinal && text.count >= lineLength
        ))
        nextID += 1
        if lines.count > kept { lines.removeFirst(lines.count - kept) }
    }

    /// They left, or stopped being listened to: their line ends where it is, and anything
    /// still pending was never settled on, so it goes.
    mutating func close(speakerID: String) {
        for index in lines.indices where lines[index].speakerID == speakerID && !lines[index].isClosed {
            lines[index].pending = ""
            lines[index].isClosed = true
            if lines[index].settled.isEmpty { lines[index].updatedAt = .distantPast }
        }
    }

    mutating func clear() {
        lines = []
    }

    /// Everything said, oldest first, each line with who said it — what a call's summary is
    /// written from. Words never settled on are left out, except on the line still going.
    var transcript: [SummaryInput.Line] {
        lines.compactMap { line in
            let text = line.isClosed ? line.settled : line.text
            return text.isEmpty ? nil : SummaryInput.Line(author: line.speaker, text: text)
        }
    }

    /// The lines on screen now: the last few that someone added to recently.
    func visible(at now: Date = Date()) -> [CaptionLine] {
        Array(lines.filter { now.timeIntervalSince($0.updatedAt) < linger && !$0.text.isEmpty }.suffix(shown))
    }

    /// The speaker's line that new words go on, if they're still in the middle of one.
    private mutating func openLine(for speakerID: String, at now: Date) -> Int? {
        guard let index = lines.lastIndex(where: { $0.speakerID == speakerID }), !lines[index].isClosed else { return nil }
        // Words still pending belong to the line however long they took; settled ones
        // followed by a pause end it.
        if lines[index].pending.isEmpty, now.timeIntervalSince(lines[index].updatedAt) >= pause {
            lines[index].isClosed = true
            return nil
        }
        return index
    }
}
