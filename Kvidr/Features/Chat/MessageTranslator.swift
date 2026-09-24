import NaturalLanguage
import Observation
import SwiftUI
@preconcurrency import Translation

/// Translates messages on this Mac, with Apple's Translation framework — the server has no
/// translation provider, and this way no message leaves the Mac to be translated.
///
/// A message is translated when you ask from its menu, or, in a conversation set to translate
/// automatically, as it comes on screen when it isn't in your language. The translation shows
/// in the bubble under the original, as Messages does it.
///
/// A language pair macOS hasn't downloaded can only be fetched through the system's own
/// prompt, which needs a SwiftUI view to ask from: ``TranslationDownloadHost`` is that view.
@MainActor
@Observable
final class MessageTranslator {
    enum State: Equatable {
        case working
        case done(text: String, from: Locale.Language)
        /// Already in the language it would be translated into.
        case sameLanguage
        case failed(String)
    }

    /// What a message's row shows.
    enum Display: Equatable {
        case working
        case done(text: String, fromName: String)
        case problem(String)
    }

    private(set) var states: [String: State] = [:]
    /// Translations put away with "Show Original" — kept, so they stay away when the
    /// conversation translates by itself.
    private(set) var hidden: Set<String> = []
    /// Asked for from the menu rather than automatically: only these say when they fail.
    @ObservationIgnored private var askedFor: Set<String> = []
    /// The language pair waiting on the system's download prompt, if one is.
    private(set) var download: TranslationSession.Configuration?
    @ObservationIgnored private var waiting: [Pending] = []
    /// Pairs whose download was turned down: not asked about again this session.
    @ObservationIgnored private var declined: Set<String> = []
    @ObservationIgnored private var sessions: [String: TranslationSession] = [:]
    /// Outgoing translations waiting on a download, by language pair.
    @ObservationIgnored private var downloadWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// Downloads asked for while another one's prompt is up.
    @ObservationIgnored private var queuedDownloads: [TranslationSession.Configuration] = []
    @ObservationIgnored private let preferences: Preferences

    private struct Pending {
        let key: String
        let text: String
        let source: Locale.Language
    }

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// The language messages are translated into: the one chosen in Settings, or the Mac's.
    var target: Locale.Language {
        Locale.Language(identifier: preferences.translationLanguage ?? Locale.preferredLanguages.first ?? "en")
    }

    static func key(_ message: Message) -> String {
        "\(message.token)#\(message.messageID)"
    }

    // MARK: - Asking

    func isAutomatic(in token: String) -> Bool {
        preferences.autoTranslatedConversations.contains(token)
    }

    func setAutomatic(_ on: Bool, in token: String) {
        if on {
            preferences.autoTranslatedConversations.insert(token)
        } else {
            preferences.autoTranslatedConversations.remove(token)
        }
    }

    /// From the message's menu.
    func translate(_ message: Message, text: String) {
        let key = Self.key(message)
        hidden.remove(key)
        askedFor.insert(key)
        if case .done = states[key] { return }
        start(key, text: text, byHand: true)
    }

    /// As it comes on screen, in a conversation that translates by itself. Short messages —
    /// "ok", "haha" — are left alone: there's too little to tell the language by.
    func translateAutomatically(_ message: Message, text: String) {
        let key = Self.key(message)
        guard states[key] == nil, !hidden.contains(key), text.count >= 12 else { return }
        start(key, text: text, byHand: false)
    }

    /// "Show Original".
    func hide(_ message: Message) {
        hidden.insert(Self.key(message))
    }

    func display(for message: Message) -> Display? {
        let key = Self.key(message)
        guard !hidden.contains(key), let state = states[key] else { return nil }
        let byHand = askedFor.contains(key)
        switch state {
        case .done(let text, let from):
            return .done(text: text, fromName: Self.nameInSentence(of: from))
        case .working:
            return byHand ? .working : nil
        case .sameLanguage:
            return byHand ? .problem(String(localized: "This is already in \(Self.nameInSentence(of: target)).", comment: "Translating a message; %@ is a language")) : nil
        case .failed(let reason):
            return byHand ? .problem(reason) : nil
        }
    }

    // MARK: - Translating before sending

    /// The language a draft here was last translated into: offered first next time.
    func outgoingLanguage(for token: String) -> Locale.Language? {
        preferences.outgoingTranslations[token].map(Locale.Language.init(identifier:))
    }

    func setOutgoingLanguage(_ language: Locale.Language?, for token: String) {
        preferences.outgoingTranslations[token] = language?.minimalIdentifier
    }

    enum OutgoingResult: Equatable {
        case translated(String)
        /// Written in that language already.
        case sameLanguage
        case failed(String)
    }

    /// A draft — or the part of it that was selected — in `target`, to read over before it's
    /// sent.
    func translateOutgoing(_ text: String, to target: Locale.Language) async -> OutgoingResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .sameLanguage }
        guard let source = Self.language(of: text, sure: false) else {
            return .failed(String(localized: "kvidr couldn’t tell which language you wrote in."))
        }
        if source.languageCode == target.languageCode { return .sameLanguage }
        var status = await LanguageAvailability().status(from: source, to: target)
        if status == .supported {
            // macOS fetches the language first, through its own prompt.
            guard await requestDownload(source, target) else {
                return .failed(String(localized: "\(Self.name(of: target)) wasn’t downloaded for translation.", comment: "%@ is a language"))
            }
            status = await LanguageAvailability().status(from: source, to: target)
        }
        guard status == .installed else {
            return .failed(String(localized: "\(Self.name(of: source)) can’t be translated into \(Self.nameInSentence(of: target)) on this Mac.", comment: "%1$@ and %2$@ are languages"))
        }
        do {
            return .translated(try await session(from: source, to: target).translate(text).targetText)
        } catch {
            Log.ui.warning("Couldn’t translate the draft: \(error.localizedDescription)")
            return .failed(String(localized: "Your message couldn’t be translated."))
        }
    }

    private func requestDownload(_ source: Locale.Language, _ target: Locale.Language) async -> Bool {
        let pair = Self.pair(source, target)
        guard !declined.contains(pair) else { return false }
        return await withCheckedContinuation { continuation in
            downloadWaiters[pair, default: []].append(continuation)
            let configuration = TranslationSession.Configuration(source: source, target: target)
            if download == nil {
                download = configuration
            } else if download != configuration, !queuedDownloads.contains(configuration) {
                queuedDownloads.append(configuration)
            }
        }
    }

    /// The target language changed: what was translated is in the wrong one now.
    func reset() {
        states = [:]
        hidden = []
        askedFor = []
        waiting = []
        declined = []
        sessions = [:]
        download = nil
        queuedDownloads = []
        for waiters in downloadWaiters.values { waiters.forEach { $0.resume(returning: false) } }
        downloadWaiters = [:]
    }

    // MARK: - Translating

    private func start(_ key: String, text: String, byHand: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let source = Self.language(of: text, sure: !byHand) else {
            states[key] = .failed(String(localized: "kvidr couldn’t tell which language this is in."))
            return
        }
        if source.languageCode == target.languageCode {
            states[key] = .sameLanguage
            return
        }
        states[key] = .working
        Task { await run(Pending(key: key, text: text, source: source)) }
    }

    private func run(_ item: Pending) async {
        let target = self.target
        switch await LanguageAvailability().status(from: item.source, to: target) {
        case .installed:
            do {
                let response = try await session(from: item.source, to: target).translate(item.text)
                states[item.key] = .done(text: response.targetText, from: item.source)
            } catch {
                Log.ui.warning("Couldn’t translate a message: \(error.localizedDescription)")
                states[item.key] = .failed(String(localized: "This message couldn’t be translated."))
            }
        case .supported:
            // macOS has to fetch the language first, and only its own prompt can.
            let pair = Self.pair(item.source, target)
            guard !declined.contains(pair) else {
                states[item.key] = .failed(String(localized: "\(Self.name(of: item.source)) isn’t downloaded for translation.", comment: "%@ is a language"))
                return
            }
            waiting.append(item)
            if download == nil { download = TranslationSession.Configuration(source: item.source, target: target) }
        case .unsupported:
            states[item.key] = .failed(String(localized: "\(Self.name(of: item.source)) can’t be translated into \(Self.nameInSentence(of: target)) on this Mac.", comment: "%1$@ and %2$@ are languages"))
        @unknown default:
            states[item.key] = .failed(String(localized: "This message couldn’t be translated."))
        }
    }

    /// The system's prompt was answered — the language downloaded, or not.
    func downloadFinished(downloaded: Bool) {
        guard let configuration = download, let source = configuration.source, let target = configuration.target else { return }
        download = nil
        let pair = Self.pair(source, target)
        let ready = waiting.filter { Self.pair($0.source, target) == pair }
        waiting.removeAll { Self.pair($0.source, target) == pair }
        if !downloaded { declined.insert(pair) }
        for item in ready {
            if downloaded {
                Task { await run(item) }
            } else {
                states[item.key] = .failed(String(localized: "\(Self.name(of: source)) wasn’t downloaded for translation.", comment: "%@ is a language"))
            }
        }
        downloadWaiters.removeValue(forKey: pair)?.forEach { $0.resume(returning: downloaded) }
        // Another language waiting its turn.
        if let next = waiting.first {
            download = TranslationSession.Configuration(source: next.source, target: target)
        } else if !queuedDownloads.isEmpty {
            download = queuedDownloads.removeFirst()
        }
    }

    private func session(from source: Locale.Language, to target: Locale.Language) -> TranslationSession {
        let pair = Self.pair(source, target)
        if let session = sessions[pair] { return session }
        let session = TranslationSession(installedSource: source, target: target)
        sessions[pair] = session
        return session
    }

    private static func pair(_ source: Locale.Language, _ target: Locale.Language) -> String {
        "\(source.minimalIdentifier)>\(target.minimalIdentifier)"
    }

    /// The language a text is in. `sure`: only when the guess is a confident one — for
    /// translating unasked, where a wrong guess would put a nonsense translation on screen.
    private static func language(of text: String, sure: Bool) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined,
              !sure || confidence >= 0.7
        else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// Every language the Mac can translate into, for the Settings picker.
    nonisolated static func supportedLanguages() async -> [Locale.Language] {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        return supported
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { name(of: $0) < name(of: $1) }
    }

    /// A language's name, in the Mac's own language — "engelsk" on a Danish Mac.
    nonisolated static func name(of language: Locale.Language) -> String {
        let name = Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A language's name as it reads inside a sentence — "English" in English, but "engelsk"
    /// in Danish, where language names aren't capitalized.
    nonisolated static func nameInSentence(of language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }
}

/// Where the system asks to download a language for translation. Invisible; it only asks
/// when the translator has a language pair waiting.
struct TranslationDownloadHost: View {
    let translator: MessageTranslator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(translator.download) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { translator.downloadFinished(downloaded: true) }
                } catch {
                    await MainActor.run { translator.downloadFinished(downloaded: false) }
                }
            }
    }
}
