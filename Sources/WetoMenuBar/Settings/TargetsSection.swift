import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WetoShared

struct TargetsSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    @State private var newTarget = ""

    var body: some View {
        Section {
            if coordinator.settings.targets.isEmpty {
                Text("Цели не выбраны — охрана ничего не завершает")
                    .foregroundStyle(.secondary)
            }

            ForEach(coordinator.settings.targets, id: \.self) { entry in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coordinator.guardVM.displayName(forTarget: entry))
                        Text(coordinator.guardVM.resolvedDescription(forTarget: entry))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 0)

                    Text(verbatim: "процессов: \(coordinator.guardVM.runningProcessCount(forTarget: entry))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        remove(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить цель \(entry)")
                    .help("Удалить цель")
                }
            }

            LabeledContent("Новая цель") {
                HStack(spacing: 8) {
                    TextField("", text: $newTarget, prompt: Text("nano, /usr/bin/curl, com.openai.chat"))
                        .labelsHidden()
                        .onSubmit { add() }
                    Button("Добавить") { add() }
                        .disabled(newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Выбрать…") { pickFromDisk() }
                }
            }
        } header: {
            Text("Цели")
        } footer: {
            Text("""
                Приложение, бинарник или команда терминала — всё в одном списке. \
                Можно ввести имя (`nano`), путь (`/usr/bin/curl`) или выбрать файл. \
                Дочерние процессы целей завершаются вместе с родителем.
                """)
            .foregroundStyle(.secondary)
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
