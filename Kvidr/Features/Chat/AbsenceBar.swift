import SwiftUI

/// Over a one-to-one with someone who is out of office: until when, what they said, and who
/// to ask instead — the way Talk's web app puts it at the top of the conversation. One line,
/// with the long message a click away.
struct AbsenceBar: View {
    let name: String
    let absence: Absence
    var onMessageReplacement: (() -> Void)?
    var onDismiss: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)

                Text("\(Text("\(firstName) is away until \(until)").fontWeight(.medium))\(Text(absence.shortMessage.isEmpty ? "" : " · \(absence.shortMessage)").foregroundStyle(.secondary))")
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if hasMore {
                    Button(isExpanded
                           ? String(localized: "Less", comment: "Out-of-office bar: show less of the absence message")
                           : String(localized: "absence.more", defaultValue: "More", comment: "Out-of-office bar: show all of the absence message")) {
                        withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
                    }
                    .buttonStyle(.link)
                    .fixedSize()
                }
                if let onMessageReplacement {
                    Button("Message \(replacementFirstName)", action: onMessageReplacement)
                        .buttonStyle(.link)
                        .fixedSize()
                        .help(absence.replacementDisplayName.map { String(localized: "Ask \($0) instead", comment: "Tooltip: message the absent person's stand-in; %@ is the stand-in's name") }
                            ?? String(localized: "Ask their stand-in instead", comment: "Tooltip: message the absent person's stand-in, whose name isn't known"))
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide")
                .accessibilityLabel("Hide out-of-office")
            }

            if isExpanded {
                Text(absence.message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .glass(.panel, cornerRadius: 10)
    }

    private var until: String {
        absence.lastDay().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private var hasMore: Bool {
        !absence.message.isEmpty && absence.message != absence.shortMessage
    }

    private var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    private var replacementFirstName: String {
        let full = absence.replacementDisplayName ?? absence.replacementUserID ?? String(localized: "stand-in", comment: "Stands in for the name of an absent person's replacement, in “Message stand-in”")
        return full.split(separator: " ").first.map(String.init) ?? full
    }
}
