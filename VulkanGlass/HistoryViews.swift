import AppKit
import SwiftUI

/// Confirms resetting the vault's branch to the commit being viewed in history mode.
@MainActor
enum HistoryResetAlert {
    static func make(commit: GitCommit, hasRemote: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset to commit \(commit.shortHash)?"
        alert.informativeText = informativeText(commit: commit, hasRemote: hasRemote)
        let reset = alert.addButton(withTitle: "Reset")
        reset.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        // Losing work must not be the Return-key default.
        reset.keyEquivalent = ""
        return alert
    }

    static func informativeText(commit: GitCommit, hasRemote: Bool) -> String {
        let subject = commit.subject.isEmpty ? commit.shortHash : "“\(commit.subject)”"
        var text = "The vault will be reset to \(subject). Every change made after this commit "
            + "will be lost."
        if hasRemote {
            text += " The reset replaces the branch on the remote the next time the vault syncs."
        }
        return text + " This cannot be undone."
    }
}

/// The status bar's popover: the vault branch's newest commits. Choosing one checks it out.
struct CommitHistoryPopover: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            Text("Showing the \(GitService.commitHistoryLimit) most recent commits")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .frame(width: 380, height: 440)
        .task { await model.loadCommitHistory() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                if let branch = model.historyCheckout?.branch ?? model.vault?.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.historyOpen = false
                Task { await model.syncNow() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(model.isReadOnly || model.gitStatus?.state == .syncing)
            .help(model.isReadOnly ? "Syncing is paused in read-only history mode" : "Commit and sync with GitHub")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.commitHistory.isEmpty {
            Group {
                if model.loadingCommitHistory {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No commits yet")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.commitHistory.enumerated()), id: \.element.id) { index, commit in
                        CommitHistoryRow(
                            commit: commit,
                            isLatest: index == 0,
                            isCheckedOut: commit.hash == model.checkedOutCommitHash
                        ) {
                            model.historyOpen = false
                            Task { await model.checkoutCommit(commit.hash) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct CommitHistoryRow: View {
    let commit: GitCommit
    let isLatest: Bool
    let isCheckedOut: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isCheckedOut ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(isCheckedOut ? VGTheme.accent : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                            .font(.system(size: 12, weight: isCheckedOut ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if isLatest {
                            Text("Latest")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(VGTheme.accent.opacity(0.2)))
                                .foregroundStyle(VGTheme.accentHover)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(commit.shortHash)
                            .font(.system(size: 10, design: .monospaced))
                        Text(commit.author)
                            .lineLimit(1)
                        Text(commit.date, format: .relative(presentation: .named))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCheckedOut
                        ? VGTheme.accent.opacity(0.14)
                        : (hovering ? Color.primary.opacity(0.06) : Color.clear))
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isCheckedOut ? "Checked out" : "Check out \(commit.shortHash) read-only")
    }
}

/// Bar above the status bar while an earlier commit is checked out.
struct HistoryModeBanner: View {
    @Environment(AppModel.self) private var model
    let checkout: HistoryCheckout

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(VGTheme.textAccent)
            Text("Read only history mode")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VGTheme.textNormal(dark: model.dark))
            Text("\(checkout.commit.shortHash) · \(checkout.commit.subject)")
                .font(.system(size: 11))
                .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Return to latest") {
                Task { await model.returnToLatestCommit() }
            }
            .controlSize(.small)
            .help("Leave history mode on the newest commit of \(checkout.branch)")
            Button("Reset to current commit") {
                Task { await model.resetToHistoryCommit() }
            }
            .controlSize(.small)
            .help("Reset \(checkout.branch) to \(checkout.commit.shortHash), discarding later commits")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(VGTheme.accent.opacity(model.dark ? 0.16 : 0.12))
        .background(VGTheme.backgroundSecondary(dark: model.dark))
        .overlay(alignment: .top) {
            VGTheme.accent.opacity(0.5).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Read only history mode")
    }
}
