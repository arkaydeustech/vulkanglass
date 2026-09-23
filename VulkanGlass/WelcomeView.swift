import SwiftUI

/// Vault picker shown on launch.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: VGTheme.titleBarHeight)
            Spacer()
            HStack(spacing: 0) {
                leftColumn
                rightColumn
            }
            .frame(maxWidth: 880, maxHeight: 520)
            .background(VGTheme.backgroundSecondary(dark: model.dark))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(VGTheme.divider(dark: model.dark), lineWidth: 1)
            )
            Spacer()
        }
        .background(VGTheme.backgroundPrimary(dark: model.dark))
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LogoView(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vulkan Glass").font(.title3.weight(.semibold))
                    Text("Markdown notes. Vaults are GitHub repositories.")
                        .font(.caption)
                        .foregroundStyle(VGTheme.textMuted(dark: model.dark))
                }
            }
            .padding(.bottom, 8)

            action("plus", "Create GitHub vault", "New private or public repository") {
                model.createOpen = true
            }
            action("arrow.down.doc", "Clone GitHub vault", "Open an existing repository as a vault") {
                model.cloneOpen = true
            }
            action("folder", "Open local repository", "Folder that already has a GitHub remote") {
                Task { await model.openLocalVault() }
            }
            action("doc", "Open Markdown file", "Edit a .md file that is not in a vault") {
                model.openStandaloneFile()
            }
            action("key", model.githubUser.map { "GitHub: \($0.login)" } ?? "Connect GitHub",
                   githubSubtitle) {
                model.settingsOpen = true
            }

            if let busy = model.busyMessage {
                Text(busy).font(.caption).foregroundStyle(VGTheme.textAccent)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
            let recents = model.settings.recentItems
            if recents.isEmpty {
                Spacer()
                Text("No recent vaults or files yet.")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recents) { item in
                            recentRow(item)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VGTheme.backgroundPrimary(dark: model.dark))
    }

    private func recentRow(_ item: RecentItem) -> some View {
        Button {
            Task { await model.openRecent(item) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbolName)
                    .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(VGTheme.hover(dark: model.dark).opacity(0.001))
        .help(item.path)
        .contextMenu {
            Button("Remove from Recents") { model.removeRecent(item) }
        }
    }

    private func action(_ symbol: String, _ title: String, _ subtitle: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(VGTheme.textAccent)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(VGTheme.textNormal(dark: model.dark))
                    Text(subtitle).font(.caption).foregroundStyle(VGTheme.textMuted(dark: model.dark))
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var githubSubtitle: String {
        if model.authenticationDisabled {
            return "Disabled for this local-only development launch"
        }
        if model.githubUser != nil {
            return model.githubAuthSource == .gitHubCLI
                ? "Connected via GitHub CLI"
                : "Personal access token for clone, create, and sync"
        }
        if model.githubCLIStatus.isInstalled, model.settings.useGitHubCLI {
            return "GitHub CLI detected — run gh auth login, or add a token"
        }
        return "Personal access token for clone, create, and sync"
    }
}

extension RecentItem {
    var symbolName: String {
        switch self {
        case .vault: "folder"
        case .file: "doc.text"
        }
    }

    /// The remote for a GitHub vault, otherwise where the vault or file lives.
    var detail: String {
        switch self {
        case .vault(let vault): vault.remote ?? (vault.path as NSString).abbreviatingWithTildeInPath
        case .file(let file): (file.path as NSString).abbreviatingWithTildeInPath
        }
    }
}
