import SwiftUI

/// Live Captions on the call's stage: the last few lines, newest at the bottom, each under the
/// name of whoever said it — the name left out when the line before was theirs too. Words the
/// model is still hearing are a shade lighter until it settles on them. Dark rather than
/// glass: captions have to be readable over any video.
struct CaptionsView: View {
    let captions: LiveCaptions

    var body: some View {
        // Once a second, so lines leave the screen when they've been there long enough.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lines = captions.log.visible(at: context.date)
            content(lines: lines)
                .animation(.smooth(duration: 0.25), value: lines.map(\.id))
                .animation(.smooth(duration: 0.25), value: note)
        }
    }

    @ViewBuilder
    private func content(lines: [CaptionLine]) -> some View {
        if note != nil || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let note {
                    Label(note, systemImage: "captions.bubble")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    VStack(alignment: .leading, spacing: 2) {
                        if index == 0 || lines[index - 1].speakerID != line.speakerID {
                            Text(line.speaker)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        line.styledText
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            // A long stretch of talking shows its newest words.
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .leading)
            .background(.black.opacity(0.62), in: .rect(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(lines))
            .transition(.opacity)
        }
    }

    private var note: String? { captions.note }

    private func accessibilityText(_ lines: [CaptionLine]) -> String {
        let spoken = lines.map { "\($0.speaker): \($0.text)" }
        return ((note.map { [$0] } ?? []) + spoken).joined(separator: ". ")
    }
}

/// Live Captions in the floating mini call while you share your screen: the latest two lines,
/// small, each after the speaker's name — in a space that stays the same size, so the window
/// doesn't jump as people start and stop talking.
struct CompactCaptionsView: View {
    let captions: LiveCaptions
    let width: CGFloat
    let cornerRadius: CGFloat

    private static let padding: CGFloat = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lines = Array(captions.log.visible(at: context.date).suffix(2))
            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty {
                    Label(captions.note ?? "Live Captions", systemImage: "captions.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                } else {
                    ForEach(lines) { line in
                        Text("\(Text(line.speaker).fontWeight(.semibold).foregroundStyle(.white.opacity(0.65)))  \(line.styledText)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .truncationMode(.head)
                            .transition(.opacity)
                    }
                }
            }
            .animation(.smooth(duration: 0.2), value: lines.map(\.id))
            .frame(width: width - Self.padding * 2, height: 64, alignment: .bottomLeading)
            .clipped()
            .padding(Self.padding)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lines.isEmpty ? (captions.note ?? "Live Captions") : lines.map { "\($0.speaker): \($0.text)" }.joined(separator: ". "))
        }
    }
}

extension CaptionLine {
    /// The settled words, then the ones still being heard a shade lighter.
    var styledText: Text {
        if settled.isEmpty { return Text(pending).foregroundStyle(.white.opacity(0.7)) }
        if pending.isEmpty { return Text(settled) }
        return Text("\(settled) \(Text(pending).foregroundStyle(.white.opacity(0.7)))")
    }
}

extension LiveCaptions {
    /// Getting ready, or why there are none: said where the captions would be.
    var note: String? {
        switch status {
        case .off, .on: nil
        case .preparing(let text), .problem(let text): text
        }
    }
}

extension LiveCaptions {
    /// The captions part of the call's More menu: on and off, and which language.
    var menuItems: [PopUpMenuItem] {
        var items: [PopUpMenuItem] = [.header("Captions")]
        let isOn = self.isOn
        items.append(.action("Live Captions", isChecked: isOn) { self.setOn(!isOn) })
        guard isOn else { return items }
        var languages: [PopUpMenuItem] = [
            .action(automaticTitle, isChecked: chosenLanguage == nil) { self.setLanguage(nil) },
        ]
        if !choices.isEmpty { languages.append(.divider) }
        for locale in choices {
            languages.append(.action(Self.name(of: locale), isChecked: chosenLanguage == locale.identifier) {
                self.setLanguage(locale.identifier)
            })
        }
        items.append(.submenu("Language", languages))
        return items
    }

    /// "Automatic", with the language that means right now.
    private var automaticTitle: String {
        guard chosenLanguage == nil, let language else { return "Automatic" }
        return "Automatic (\(Self.name(of: language)))"
    }
}
