import SwiftUI

struct AboutView: View {
    @ObservedObject var updateManager: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            updateSection

            if case .updateAvailable(let update) = updateManager.status,
               let notes = update.notes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notesSection(update, notes: notes)
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Group {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").resizable().scaledToFit()
                }
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("Orbit").font(.title.bold())
                Text("原生 macOS SSH 终端").foregroundStyle(.secondary)
                Text(updateManager.currentVersion.displayText)
                    .font(.caption)
                    .accessibilityIdentifier("aboutVersionLabel")
            }
        }
    }

    private var updateSection: some View {
        SettingsGroup("更新") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    statusIcon
                    Text(updateManager.status.statusText)
                        .accessibilityIdentifier("aboutUpdateStatusLabel")
                }
                Text("更新渠道：稳定版").foregroundStyle(.secondary)
                Text("上次检查：\(lastCheckText)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("aboutLastCheckLabel")
                Toggle("自动检查更新", isOn: Binding(
                    get: { updateManager.automaticallyChecksForUpdates },
                    set: { updateManager.setAutomaticallyChecksForUpdates($0) }
                ))
                .toggleStyle(.switch)
                .disabled(updateManager.isDisabledForTesting)
                .accessibilityIdentifier("aboutAutoCheckToggle")
                updateButton
                    .disabled(updateManager.isDisabledForTesting
                              || !updateManager.canCheckForUpdates
                              || updateManager.status == .checking)
            }
        }
    }

    private func notesSection(_ update: AvailableUpdate, notes: String) -> some View {
        SettingsGroup("更新说明") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    ReleaseNotesView(markdown: notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .accessibilityIdentifier("aboutReleaseNotes")

                if let url = update.fullNotesURL ?? update.releasePageURL {
                    Link("查看完整更新说明", destination: url)
                        .font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if case .updateAvailable(let update) = updateManager.status {
            Button("安装更新 \(update.displayVersion)") {
                updateManager.checkForUpdates()
            }
            .accessibilityIdentifier("aboutInstallUpdateButton")
        } else {
            Button(updateManager.status == .checking ? "正在检查…" : "检查更新") {
                updateManager.checkForUpdateInformation()
            }
            .accessibilityIdentifier("aboutCheckForUpdatesButton")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updateManager.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .updateAvailable:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .newerThanFeed:
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        case .disabled:
            Image(systemName: "gearshape").foregroundStyle(.secondary)
        case .idle:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private var lastCheckText: String {
        guard let date = updateManager.lastCheckDate else { return "从未" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
