import SwiftUI
import UniformTypeIdentifiers

// why: C6 — a Transferable document so the JSONL/text share produces a real file with the right
// extension in the share sheet (Files, Mail, AirDrop) rather than an untyped text blob. Local-only:
// the bytes are the already-persisted transcript, nothing new leaves the device that the user
// didn't explicitly share.
private struct TranscriptExportFile: Transferable {
  let text: String
  let filename: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .plainText) { file in
      Data(file.text.utf8)
    }
    .suggestedFileName { $0.filename }
  }
}

// why: session-metadata formatting (C7) kept pure and off the views — duration is honest "—" for a
// recovered session (no clean end), engine is "—" when a pre-C7 summary never recorded it.
enum SessionMetadataFormat {
  static func duration(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "—" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }

  static func engine(_ engineDisplayName: String?) -> String {
    guard let engineDisplayName, !engineDisplayName.isEmpty else { return "—" }
    return engineDisplayName
  }
}

@MainActor
struct SessionHistoryView: View {
  let store: any TranscriptStoring

  @Environment(\.dismiss) private var dismiss
  @State private var sessions: [TranscriptSessionSummary] = []
  @State private var failureMessage: String?
  @State private var pendingDelete: TranscriptSessionSummary?

  var body: some View {
    NavigationStack {
      List {
        if let failureMessage {
          Text(failureMessage)
            .font(.footnote)
            .foregroundStyle(DspeechTheme.warning)
        }
        if sessions.isEmpty {
          ContentUnavailableView(
            String(localized: "No saved sessions"),
            systemImage: "clock",
            description: Text(String(localized: "Completed transcripts will appear here."))
          )
        } else {
          ForEach(sessions) { session in
            NavigationLink {
              SessionHistoryDetailView(store: store, session: session)
            } label: {
              SessionSummaryRow(session: session)
            }
            .accessibilityIdentifier("session-history-row")
            .swipeActions {
              Button(role: .destructive) {
                pendingDelete = session
              } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
              }
            }
          }
        }
      }
      .accessibilityIdentifier("session-history-list")
      .navigationTitle(String(localized: "Session history"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(String(localized: "Done")) {
            dismiss()
          }
        }
      }
      .onAppear { reload() }
      .confirmationDialog(
        String(localized: "Delete saved session?"),
        isPresented: Binding(
          get: { pendingDelete != nil },
          set: { if !$0 { pendingDelete = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingDelete
      ) { session in
        Button(String(localized: "Delete"), role: .destructive) {
          delete(session)
        }
        Button(String(localized: "Cancel"), role: .cancel) {}
      } message: { _ in
        Text(
          String(
            localized:
              "This deletes the saved transcript from this device. Current view is unchanged."))
      }
    }
    .preferredColorScheme(.dark)
  }

  private func reload() {
    do {
      sessions = try store.sessions()
      failureMessage = nil
    } catch {
      failureMessage = String(localized: "Couldn't load session history.")
    }
  }

  private func delete(_ session: TranscriptSessionSummary) {
    do {
      try store.deleteSession(session.id)
      pendingDelete = nil
      reload()
    } catch {
      failureMessage = String(localized: "Couldn't delete the saved session.")
    }
  }
}

private struct SessionSummaryRow: View {
  let session: TranscriptSessionSummary

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Text(
          String(localized: "\(session.segmentCount) transmissions - \(session.localeIdentifier)")
        )
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
        // why: C7 — duration + engine surfaced as a compact second metadata line; honest "—" when a
        // recovered session has no clean duration or a pre-C7 summary recorded no engine.
        Text(
          String(
            localized:
              "\(SessionMetadataFormat.duration(session.durationSeconds)) · \(SessionMetadataFormat.engine(session.engineDisplayName))"
          )
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityIdentifier("session-history-row-metadata")
      }
      Spacer(minLength: 0)
      SessionStatusBadge(recovered: session.endedAt == nil)
    }
  }
}

// why: two-tier badge (D14 rule) makes the two states visually distinct at a glance — a recovered
// session (crash-recovered, no clean end) is the notable state, so it reads as a FILLED warning
// capsule; a cleanly-saved session is the quiet norm, so it reads as an OUTLINE success capsule.
// Both derive their colour and insets from DspeechTheme, no per-view literals.
private struct SessionStatusBadge: View {
  let recovered: Bool

  private var tint: Color { recovered ? DspeechTheme.warning : DspeechTheme.success }

  private var label: String {
    recovered ? String(localized: "Recovered") : String(localized: "Saved")
  }

  var body: some View {
    Text(label)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        if recovered {
          Capsule().fill(tint.opacity(DspeechTheme.chipFillOpacity))
        }
      }
      .overlay {
        if !recovered {
          Capsule().stroke(tint.opacity(DspeechTheme.chipStrokeOpacity), lineWidth: 1)
        }
      }
      .accessibilityIdentifier(recovered ? "session-status-recovered" : "session-status-saved")
  }
}

@MainActor
private struct SessionHistoryDetailView: View {
  let store: any TranscriptStoring
  let session: TranscriptSessionSummary

  @State private var segments: [TranscriptSegment] = []
  @State private var exportText: String?
  @State private var exportJSONL: String?
  @State private var failureMessage: String?

  var body: some View {
    List {
      if let failureMessage {
        Text(failureMessage)
          .font(.footnote)
          .foregroundStyle(DspeechTheme.warning)
      }
      Section {
        LabeledContent(
          String(localized: "Duration"),
          value: SessionMetadataFormat.duration(session.durationSeconds)
        )
        .accessibilityIdentifier("session-detail-duration")
        LabeledContent(
          String(localized: "Engine"),
          value: SessionMetadataFormat.engine(session.engineDisplayName)
        )
        .accessibilityIdentifier("session-detail-engine")
        LabeledContent(String(localized: "Recognition language"), value: session.localeIdentifier)
          .accessibilityIdentifier("session-detail-locale")
      } header: {
        Text(String(localized: "Session"))
      }
      Section {
        ForEach(segments) { segment in
          VStack(alignment: .leading, spacing: 6) {
            Text(segment.startedAt.formatted(date: .omitted, time: .standard))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Text(segment.text)
              .font(.body.monospaced())
            HStack(spacing: 10) {
              Text(segment.sourceLanguageCode.uppercased())
              if segment.requiresVerification {
                Text(String(localized: "Verify"))
              }
              Spacer(minLength: 0)
              Text(segment.confidence.formatted(.percent.precision(.fractionLength(0))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
      }
    }
    .accessibilityIdentifier("session-history-detail")
    .navigationTitle(String(localized: "Transcript"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if let exportText, let exportJSONL {
          Menu {
            ShareLink(
              item: TranscriptExportFile(text: exportText, filename: exportFilename(ext: "txt")),
              preview: SharePreview(String(localized: "Transcript (text)"))
            ) {
              Label(String(localized: "Share as text"), systemImage: "doc.plaintext")
            }
            .accessibilityIdentifier("session-history-share-text")
            ShareLink(
              item: TranscriptExportFile(text: exportJSONL, filename: exportFilename(ext: "jsonl")),
              preview: SharePreview(String(localized: "Transcript (JSONL)"))
            ) {
              Label(String(localized: "Share as JSONL"), systemImage: "curlybraces")
            }
            .accessibilityIdentifier("session-history-share-jsonl")
          } label: {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
          }
          .accessibilityIdentifier("session-history-share")
        }
      }
    }
    .onAppear { load() }
  }

  private func exportFilename(ext: String) -> String {
    "Dspeech-transcript-\(session.id.uuidString.prefix(8)).\(ext)"
  }

  private func load() {
    do {
      segments = try store.segments(in: session.id)
      exportText = try store.exportText(for: session.id)
      exportJSONL = try store.exportJSONL(for: session.id)
      failureMessage = nil
    } catch {
      failureMessage = String(localized: "Couldn't load this transcript.")
    }
  }
}
