import SwiftUI

/// In the inspector, for moderators: the bots installed on the server, each switched on or off
/// for this conversation. Ones the administrator set up stay on; ones whose app is off can't
/// be used. Nothing shows when the server has no bots.
struct BotsCard: View {
    let session: Session
    let token: String

    @State private var bots: [ConversationBot] = []
    @State private var changing: Set<Int> = []
    @State private var problem: String?

    var body: some View {
        if !bots.isEmpty || problem != nil {
            InspectorCard(title: String(localized: "Bots", comment: "Inspector card heading")) {
                ForEach(bots) { bot in
                    row(bot)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Color.clear
            .frame(height: 0)
            .task(id: token) { await load() }
    }

    private func row(_ bot: ConversationBot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 13))
                if let note = note(for: bot) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if changing.contains(bot.id) {
                ProgressView().controlSize(.small)
            }
            Toggle(bot.name, isOn: Binding(get: { bot.isOn }, set: { set(bot, on: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!bot.isAdjustable || changing.contains(bot.id))
        }
    }

    private func note(for bot: ConversationBot) -> String? {
        switch bot.state {
        case .managed: String(localized: "Set up by your administrator", comment: "A bot that is always on")
        case .unavailable: String(localized: "Not available on this server right now", comment: "A bot whose app is off")
        case .on, .off: bot.description.isEmpty ? nil : bot.description
        }
    }

    private func load() async {
        do throws(TalkError) {
            bots = try await session.bots.bots(token: token)
            problem = nil
        } catch {
            Log.ui.info("Couldn’t list the conversation’s bots: \(error.userMessage)")
        }
    }

    private func set(_ bot: ConversationBot, on: Bool) {
        guard let index = bots.firstIndex(of: bot) else { return }
        changing.insert(bot.id)
        bots[index].state = on ? .on : .off
        Task {
            do throws(TalkError) {
                try await session.bots.setEnabled(on, botID: bot.id, token: token)
                problem = nil
            } catch {
                if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index].state = bot.state }
                problem = on
                    ? String(localized: "Couldn’t turn \(bot.name) on: \(error.userMessage)", comment: "First %@ is the bot, second the error")
                    : String(localized: "Couldn’t turn \(bot.name) off: \(error.userMessage)", comment: "First %@ is the bot, second the error")
            }
            changing.remove(bot.id)
        }
    }
}
