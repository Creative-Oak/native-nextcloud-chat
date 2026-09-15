import AppKit
import SwiftUI

/// The strip of in-flight uploads above the composer.
struct AttachmentTray: View {
    @Bindable var queue: AttachmentQueue

    var body: some View {
        if !queue.transfers.isEmpty {
            VStack(spacing: 4) {
                ForEach(queue.transfers) { transfer in
                    TransferRow(transfer: transfer) {
                        queue.retry(transfer)
                    } onCancel: {
                        queue.remove(transfer)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct TransferRow: View {
    let transfer: FileTransfer
    var onRetry: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isFailed ? .red : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(transfer.fileName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if transfer.byteCount > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(transfer.byteCount), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(isFailed ? .red : .secondary)
                }

                // No bar for a staged file: it is not going anywhere until you send, and a
                // bar stopped at nine tenths reads as something stuck.
                if !transfer.state.isFinished && !transfer.state.isStaged {
                    ProgressView(value: transfer.state.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }

            if isFailed {
                Button("Retry", action: onRetry)
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(transfer.state.isFinished || transfer.state.isStaged ? "Remove" : "Cancel")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glass(.floating, cornerRadius: 8)
    }

    private var isFailed: Bool {
        if case .failed = transfer.state { return true } else { return false }
    }

    private var symbol: String {
        switch transfer.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .uploaded: "paperclip"
        default: "arrow.up.doc"
        }
    }

    private var statusText: String {
        switch transfer.state {
        case .queued: "Waiting"
        case .uploading(let fraction): "\(Int(fraction * 100))%"
        case .uploaded: "Ready to send"
        case .sharing: "Sharing…"
        case .completed: "Sent"
        case .failed(let reason): reason
        }
    }
}

/// The overlay shown while a file is being dragged over the conversation.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.06)

            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32, weight: .light))
                Text("Drop to send")
                    .font(.headline)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .glass(.panel, cornerRadius: 18)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
