import SwiftUI

/// The app's Liquid Glass vocabulary.
///
/// macOS 26's `glassEffect(_:in:)` is powerful enough to make a mess with, so the choices
/// are made once, here, and the rest of the app asks for a *role* rather than a material:
///
/// - **Floating controls** — things that hover above the transcript (message actions, the
///   scroll-to-bottom button, the offline pill). Interactive glass: it responds to the
///   pointer, which is the whole point of the material.
/// - **Panels** — transient surfaces that sit over content (quick switcher, mention list,
///   emoji picker). Regular glass in a concentric rectangle so their corners agree with
///   whatever contains them.
/// - **Chips** — reaction pills. These live in a `GlassEffectContainer` so neighbouring
///   pills merge and morph as reactions come and go.
///
/// Everything else — the transcript, the sidebar rows, message text — stays ordinary
/// opaque content. Apple's guidance is that Liquid Glass belongs to the layer *above* your
/// content, not to the content itself, and a chat transcript is content.
enum GlassRole {
    /// A control cluster floating over the transcript.
    case floating
    /// A transient panel over content.
    case panel
    /// A small pill that can merge with its neighbours.
    case chip
    /// A chip the current user is part of — tinted with the accent colour.
    case selectedChip
}

extension View {
    /// Applies the app's glass treatment for a role.
    @ViewBuilder
    func glass(_ role: GlassRole, cornerRadius: CGFloat? = nil) -> some View {
        switch role {
        case .floating:
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius ?? 10))
        case .panel:
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius ?? 12))
        case .chip:
            glassEffect(.regular.interactive(), in: .capsule)
        case .selectedChip:
            glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        }
    }

    /// A circular floating control — the scroll-to-bottom button.
    func glassCircle() -> some View {
        glassEffect(.regular.interactive(), in: .circle)
    }
}

/// Spacing constants for glass containers.
///
/// The container's spacing decides how close two glass shapes have to be before they merge.
/// Reaction pills sit 4pt apart and should merge; a row of separate controls should not.
enum GlassSpacing {
    /// Reaction pills: merge readily, so adding one flows out of its neighbour.
    static let merging: CGFloat = 12
    /// Distinct controls that share a container only for rendering performance.
    static let distinct: CGFloat = 28
}

// MARK: - Session in the environment

/// The signed-in session, for the few leaf views that need to make a request of their own
/// (the "who reacted" popover, the profile card) and would otherwise need it threaded
/// through half a dozen initializers.
private struct TalkSessionKey: EnvironmentKey {
    static let defaultValue: Session? = nil
}

extension EnvironmentValues {
    var talkSession: Session? {
        get { self[TalkSessionKey.self] }
        set { self[TalkSessionKey.self] = newValue }
    }
}
