import SwiftUI

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
            .foregroundStyle(.orange)
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
        Text(
          String(localized: "\(session.segmentCount) segments - \(session.localeIdentifier)")
        )
        .font(.footnote.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      Text(session.endedAt == nil ? String(localized: "Recovered") : String(localized: "Saved"))
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .foregroundStyle(session.endedAt == nil ? Color.orange : Color.green)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          (session.endedAt == nil ? Color.orange : Color.green).opacity(0.15),
          in: Capsule()
        )
    }
  }
}

@MainActor
private struct SessionHistoryDetailView: View {
  let store: any TranscriptStoring
  let session: TranscriptSessionSummary

  @State private var segments: [TranscriptSegment] = []
  @State private var exportText: String?
  @State private var failureMessage: String?

  var body: some View {
    List {
      if let failureMessage {
        Text(failureMessage)
          .font(.footnote)
          .foregroundStyle(.orange)
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
        if let exportText {
          ShareLink(item: exportText) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
          }
          .accessibilityIdentifier("session-history-share")
        }
      }
    }
    .onAppear { load() }
  }

  private func load() {
    do {
      segments = try store.segments(in: session.id)
      exportText = try store.exportText(for: session.id)
      failureMessage = nil
    } catch {
      failureMessage = String(localized: "Couldn't load this transcript.")
    }
  }
}
