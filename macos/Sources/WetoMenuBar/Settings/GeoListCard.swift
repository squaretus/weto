import SwiftUI
import WetoCore
import WetoShared
import WetoDesign

/// Карточка списка геоправил. Экран создаёт её дважды — под чёрный и под белый
/// список. Собственные `newEntry` и `entryError` у каждого экземпляра: ввод
/// в одну карточку не должен подмешиваться в другую.
struct GeoListCard: View {

    @Environment(AppCoordinator.self) private var coordinator

    let title: String
    let emptyText: String
    /// Хвост подписи кнопки удаления: «Удалить RU из чёрного списка».
    let removalListName: String
    let entries: [String]
    let add: (String) -> Result<Void, GeoListEntryError>
    let remove: (String) -> Void

    @State private var newEntry = ""
    @State private var entryError: String?

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    var body: some View {
        WetoCard(title) {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    WetoRow {
                        Text(emptyText)
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
                                label: "Удалить \(entry) из \(removalListName)",
                                hint: "Удалить из списка"
                            ) {
                                remove(entry)
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
                    .onSubmit { commit() }

                    Button("Добавить") { commit() }
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
    private func commit() {
        switch add(newEntry) {
        case .success:
            newEntry = ""
            entryError = nil
        case .failure(let error):
            entryError = error.displayText
        }
    }
}
