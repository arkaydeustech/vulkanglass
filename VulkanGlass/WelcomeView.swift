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
        .preferredColorScheme(model.dark ? .dark : .light)
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
                   "Personal access token for clone, create, and sync") {
                model.settingsOpen = true
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
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
            Text("RECENT VAULTS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(VGTheme.textFaint(dark: model.dark))
            if model.settings.recentVaults.isEmpty {
                Spacer()
                Text("No recent GitHub vaults yet.")
                    .font(.caption)
                    .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.settings.recentVaults) { vault in
                            Button {
                                Task { await model.openVault(path: vault.path) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vault.name).foregroundStyle(VGTheme.textNormal(dark: model.dark))
                                    Text(vault.remote ?? vault.path)
                                        .font(.caption2)
                                        .foregroundStyle(VGTheme.textFaint(dark: model.dark))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(VGTheme.hover(dark: model.dark).opacity(0.001))
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VGTheme.backgroundPrimary(dark: model.dark))
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
}
