import SwiftUI

/// Compact per-stream progress bars during multi-source fetch.
struct SourceProgressView: View {
    let progresses: [SourceProgress]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(progresses) { p in
                HStack(spacing: 6) {
                    // Stream number + current source (e.g. "1 AWS" or "3 PC")
                    HStack(spacing: 2) {
                        Text(p.displayName)
                            .font(.system(size: 9).monospacedDigit().bold())
                        if !p.currentSource.isEmpty {
                            Text(p.currentSource)
                                .font(.system(size: 8).bold())
                                .foregroundStyle(sourceColor(p.currentSource))
                        }
                    }
                    .frame(width: 44, alignment: .leading)

                    ProgressView(value: p.fraction)
                        .tint(colorFor(p.status))

                    Text("\(p.completedItems)/\(p.totalItems)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private func colorFor(_ status: SourceProgress.Status) -> Color {
        switch status {
        case .idle: return .gray
        case .searching: return .blue
        case .downloading: return .green
        case .done: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }

    private func sourceColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "aws": return .orange
        case "pc": return .blue
        default: return .secondary
        }
    }
}
