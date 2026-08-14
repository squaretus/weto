import SwiftUI
import WetoCore
import WetoShared
import WetoDesign

struct BlacklistCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    @State private var newEntry = ""
    @State private var entryError: String?

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    private var entries: [String] { coordinator.settings.blockedEntries }

    var body: some View {
        WetoCard("Чёрный список") {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    WetoRow {
                        Text("Список пуст")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    }
                }

                ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                    VStack(spacing: 0) {
                        if index > 0 { WetoDivider() }

                        WetoRow {
                            Text(entry)
                                .font(WetoTokens.label)
                                .foregroundStyle(WetoTokens.ink.resolve(scheme))

                            Spacer(minLength: 0)

                            WetoDeleteRowAction(
                                label: "Удалить \(entry) из чёрного списка",
                                hint: "Удалить из списка"
                            ) {
                                coordinator.settings.removeBlockedEntry(entry)
                            }
                        }
                    }
                }

                if !entries.isEmpty { WetoDivider() }

                WetoRow {
                    TextField(
                        "",
                        text: $newEntry,
                        prompt: Text("Код страны (RU), IP или CIDR")
                    )
                    .textFieldStyle(WetoFieldStyle())
                    .labelsHidden()
                    .onSubmit { add() }

                    Button("Добавить") { add() }
                        .buttonStyle(WetoPillButtonStyle(.primary))
                        .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let entryError {
                    WetoRow {
                        Text(entryError)
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.red.resolve(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Разбор и проверку делает store: во View остаётся только показать причину отказа.
    private func add() {
        switch coordinator.settings.addBlockedEntry(newEntry) {
        case .success:
            newEntry = ""
            entryError = nil
        case .failure(let error):
            entryError = error.displayText
        }
    }
}
