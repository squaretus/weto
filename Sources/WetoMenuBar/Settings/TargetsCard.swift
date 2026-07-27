import SwiftUI
import AppKit
import WetoShared
import WetoDesign

struct TargetsCard: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var scheme

    @State private var newTarget = ""

    var body: some View {
        WetoCard("Цели") {
            VStack(spacing: 0) {
                if coordinator.settings.targets.isEmpty {
                    WetoRow {
                        Text("Цели не выбраны — охрана ничего не завершает")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    }
                }

                ForEach(Array(coordinator.settings.targets.enumerated()), id: \.element) { index, entry in
                    targetRow(entry, showsDivider: index > 0)
                }

                if !coordinator.settings.targets.isEmpty {
                    WetoDivider()
                }

                WetoRow {
                    TextField(
                        "",
                        text: $newTarget,
                        prompt: Text("nano, /usr/bin/curl, com.openai.chat")
                    )
                    .textFieldStyle(WetoFieldStyle())
                    .labelsHidden()
                    .onSubmit { add() }

                    Button("Добавить") { add() }
                        .buttonStyle(WetoPillButtonStyle(.primary))
                        .disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Выбрать…") { pickFromDisk() }
                        .buttonStyle(WetoPillButtonStyle(.ghost))
                }
            }
        }
    }

    @ViewBuilder
    private func targetRow(_ entry: String, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            if showsDivider { WetoDivider() }

            WetoRow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.guardVM.displayName(forTarget: entry))
                        .font(WetoTokens.label)
                        .foregroundStyle(WetoTokens.ink.resolve(scheme))
                    Text(coordinator.guardVM.resolvedDescription(forTarget: entry))
                        .font(WetoTokens.caption)
                        .foregroundStyle(WetoTokens.faint.resolve(scheme))
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)

                Text(verbatim: "\(coordinator.guardVM.runningProcessCount(forTarget: entry))")
                    .font(WetoTokens.data)
                    .foregroundStyle(WetoTokens.dim.resolve(scheme))

                Button {
                    remove(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                }
                .buttonStyle(WetoIconButtonStyle())
                .accessibilityLabel("Удалить цель \(entry)")
                .help("Удалить цель")
            }
        }
    }

    private func remove(_ entry: String) {
        coordinator.settings.targets = coordinator.settings.targets.filter { $0 != entry }
    }

    private func add() {
        let entry = newTarget.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty, !coordinator.settings.targets.contains(entry) else { return }
        coordinator.settings.targets += [entry]
        newTarget = ""
    }

    private func pickFromDisk() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return }

        var entries = coordinator.settings.targets
        for url in panel.urls {
            let entry = Bundle(url: url)?.bundleIdentifier ?? url.path
            if !entries.contains(entry) { entries.append(entry) }
        }
        coordinator.settings.targets = entries
    }
}
