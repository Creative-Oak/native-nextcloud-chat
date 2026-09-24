import AppKit
import SwiftUI

/// Login Flow v2, as three calm states: type an address, approve in the browser, done.
///
/// The user's Nextcloud password is never typed here — that is the whole point of Login
/// Flow v2. The app receives a device-specific app password it can revoke on its own.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var model: LoginModel

    init(app: AppModel) {
        _model = State(initialValue: LoginModel(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor.gradient)

                VStack(spacing: 4) {
                    Text("kvidr")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Connect your Nextcloud to start chatting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                switch model.phase {
                case .enteringServer, .checkingServer:
                    serverEntry
                case .waitingForBrowser:
                    waitingForBrowser
                case .finishing:
                    ProgressView("Signing in…")
                        .controlSize(.small)
                }

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        .transition(.opacity)
                }

                // Sign-out is best effort and never blocks, so this is the one place the
                // user finds out that the app password they asked to be rid of may still
                // be live. It is not an error about what they are doing now, hence the
                // quieter treatment.
                if let warning = app.signOutWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .glass(.panel, cornerRadius: 22)

            Spacer(minLength: 0)

            Text("Your Nextcloud password is never sent to this app. You’ll approve access in your browser, and can revoke it at any time in Nextcloud’s security settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 24)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 460)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var serverEntry: some View {
        VStack(spacing: 10) {
            TextField("cloud.example.com", text: $model.serverText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .frame(width: 320)
                .onSubmit { model.begin() }
                .disabled(model.phase == .checkingServer)

            Button(action: { model.begin() }) {
                if model.phase == .checkingServer {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Add Nextcloud Account")
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.serverText.trimmingCharacters(in: .whitespaces).isEmpty || model.phase == .checkingServer)
        }
    }

    private var waitingForBrowser: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Finish signing in in your browser, then come back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Open Browser Again") { model.reopenBrowser() }
                    .buttonStyle(.link)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.link)
            }
            .font(.callout)
        }
    }
}

/// The login state machine, kept out of the view.
@MainActor
@Observable
final class LoginModel {
    enum Phase: Equatable {
        case enteringServer
        case checkingServer
        case waitingForBrowser
        case finishing
    }

    var serverText = ""
    private(set) var phase: Phase = .enteringServer
    private(set) var error: String?

    private let app: AppModel
    private var session: LoginFlowSession?
    private var task: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    func begin() {
        error = nil
        app.dismissSignOutWarning()
        task?.cancel()

        let allowInsecure = app.dependencies.preferences.allowsInsecureLocalServers
        let address: ServerAddress
        do {
            address = try ServerAddress.parse(serverText, allowInsecureHTTP: allowInsecure)
        } catch {
            // Typed throws: this is always a TalkError, with a message written for a person.
            self.error = error.userMessage
            return
        }

        phase = .checkingServer
        task = Task { [weak self] in
            guard let self else { return }
            let authentication = self.app.dependencies.authentication
            do {
                // Check the server has Talk *before* sending the user to a browser, so a
                // typo doesn't end in a confusing round trip.
                _ = try await authentication.probe(server: address)

                let flow = try await authentication.beginLogin(server: address)
                self.session = flow
                self.phase = .waitingForBrowser
                NSWorkspace.shared.open(flow.loginURL)

                let result = try await authentication.completeLogin(flow)
                // Cancel, or a second attempt against a different server, replaces
                // `session`. Without this a flow that completed a moment too late would
                // still sign the app in — at the address the user had just backed out of.
                guard !Task.isCancelled, self.session == flow else {
                    // Dropping the result on the floor is not enough. By this point the app
                    // password exists on the server and sits in the keychain, and no account
                    // row is about to be saved — so nothing would ever reference it, delete
                    // it or revoke it again. Detached on purpose: this task has just been
                    // cancelled, and the revoke is an HTTP request that would be cancelled
                    // along with it.
                    Task.detached { await authentication.discardLogin(result) }
                    return
                }
                self.phase = .finishing
                await self.app.signedIn(account: result.account)
            } catch let failure as TalkError {
                guard failure != .cancelled else { return }
                self.error = Self.message(for: failure, address: address)
                self.phase = .enteringServer
            } catch {
                self.error = TalkError.unexpectedResponse("\(error)").userMessage
                self.phase = .enteringServer
            }
        }
    }

    /// An origin mismatch is the one login failure a user can act on, and the error it
    /// arrives as renders for them as "The server sent something unexpected." — true, and
    /// no help at all. kvidr refuses these on purpose, because an install whose
    /// `overwritehost` or `overwrite.cli.url` names another address is indistinguishable
    /// from a relay standing in front of one; but a refusal with nowhere to go next is a
    /// dead end. The address named here is the user's own text, normalised. The one the
    /// server claimed is deliberately not repeated — that is the untrusted half.
    private static func message(for failure: TalkError, address: ServerAddress) -> String {
        guard AuthenticationService.isOriginMismatch(failure) else { return failure.userMessage }
        return String(localized: """
        This server answers as a different address than \(address.displayString). \
        Sign in with the address your Nextcloud calls its own — the one your browser shows \
        while you’re using it.
        """, comment: "Login error: the server's configured address differs from the one typed; %@ is the typed address")
    }

    func reopenBrowser() {
        guard let session else { return }
        NSWorkspace.shared.open(session.loginURL)
    }

    func cancel() {
        task?.cancel()
        task = nil
        session = nil
        phase = .enteringServer
    }
}
