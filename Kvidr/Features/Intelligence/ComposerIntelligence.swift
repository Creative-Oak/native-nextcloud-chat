import Foundation
import Observation

/// The times named in what you are typing, kept in step with the field.
///
/// Two answers arrive, in this order, and the order is the design: the table's answer
/// lands on the same turn as the keystroke, so "i morgen" is underlined *as you type it*,
/// and the model's answer — if there is a model, and if it has anything to add — arrives a
/// few hundred milliseconds later and only ever adds phrases the table missed. There is no
/// spinner and no waiting, because there is nothing to wait for.
@MainActor
@Observable
final class ComposerIntelligence {
    /// Every phrase to underline, in the order they were typed.
    private(set) var dates: [DateExpression] = []

    @ObservationIgnored var intelligence: OnDeviceIntelligence?
    @ObservationIgnored var isEnabled = true

    @ObservationIgnored private var refineTask: Task<Void, Never>?
    @ObservationIgnored private var lastScanned: String?

    /// Called on every change to the draft. Cheap enough to be — the scanner walks the
    /// text once and allocates a token array, which for a chat message is nothing.
    func update(for text: String) {
        guard isEnabled else {
            clear()
            return
        }
        guard text != lastScanned else { return }
        lastScanned = text
        refineTask?.cancel()

        let deterministic = DateExpressionScanner().scan(text)
        dates = deterministic

        guard let intelligence, intelligence.isReady, text.count >= 8 else { return }
        refineTask = Task { [weak self] in
            // Long enough that typing a sentence doesn't queue a request per letter.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let refined = await intelligence.refinedDates(in: text, alreadyFound: deterministic)
            // The field has moved on, or the model found nothing the table hadn't: either
            // way what is on screen is already right.
            guard !Task.isCancelled, let self, self.lastScanned == text, !refined.isEmpty else { return }
            self.dates = (deterministic + refined).sorted { $0.range.lowerBound < $1.range.lowerBound }
        }
    }

    /// The phrase under a click, if the click landed on one.
    func expression(atCharacter index: Int) -> DateExpression? {
        dates.first { $0.range.contains(index) }
    }

    func clear() {
        refineTask?.cancel()
        refineTask = nil
        lastScanned = nil
        dates = []
    }
}

/// A reminder the user armed by clicking a time in their own draft, waiting for the
/// message to exist.
///
/// Talk hangs a reminder on a message id, and a message being typed has no id — so this
/// is what stands in for one between the click and the server's acknowledgement. If the
/// send fails, no reminder is set, which is the right answer: there is nothing to be
/// reminded about.
struct ArmedReminder: Sendable, Equatable {
    var date: Date
    /// The words that were clicked, for the pill's label.
    var phrase: String
}
