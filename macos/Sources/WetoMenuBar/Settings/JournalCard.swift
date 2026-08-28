import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WetoCore
import WetoShared
import WetoDesign

struct JournalCard: View {

    /// Сколько записей показывать в карточке.
    ///
    /// Хранится сто, а запись теперь на процесс: одно падение VPN — это десятки
    /// строк, и списком в окне настроек их не читают. Разбор идёт по выгрузке,
    /// поэтому на экране последние двадцать и честная строка про остальные.
    private static let visibleLimit = 20

    @Environment(AppCoordinator.self) private var coordinator

    private var scheme: ColorScheme { coordinator.settings.appTheme.colorScheme }

    private var events: [KillEvent] { coordinator.eventLog.events }

    /// Проверок в интерфейсе не видно: они материал выгрузки. Но выгружать
    /// их надо и тогда, когда завершений не было вовсе — «нажал, и ничего
    /// не произошло» это ровно тот случай.
    private var hasSomethingToExport: Bool {
        !events.isEmpty || !coordinator.checkLog.all.isEmpty
    }

    var body: some View {
        WetoCard("Журнал") {
            VStack(spacing: 0) {
                if events.isEmpty {
                    WetoRow {
                        Text("Срабатываний не было")
                            .font(WetoTokens.caption)
                            .foregroundStyle(WetoTokens.faint.resolve(scheme))
                    }
                } else {
                    ForEach(Array(events.prefix(Self.visibleLimit).enumerated()), id: \.element.id) { index, event in
                        VStack(spacing: 0) {
                            if index > 0 { WetoDivider() }
                            JournalRow(event: event)
                        }
                    }

                    if events.count > Self.visibleLimit {
                        WetoRow {
                            Text(verbatim: "Показаны последние \(Self.visibleLimit) из \(events.count) — выгрузите журнал целиком")
                                .font(WetoTokens.caption)
                                .foregroundStyle(WetoTokens.faint.resolve(scheme))
                        }
                    }
                }

                if hasSomethingToExport {
                    HStack(spacing: WetoTokens.space2) {
                        Button("Выгрузить журнал") { export() }
                            .buttonStyle(WetoPillButtonStyle(.ghost, expands: true))

                        if !events.isEmpty {
                            Button("Очистить журнал") { coordinator.eventLog.clear() }
                                .buttonStyle(WetoPillButtonStyle(.danger, expands: true))
                        }
                    }
                    .padding(.top, WetoTokens.space3)
                }
            }
        }
    }

    /// Выгрузка в файл, а не в буфер обмена: файл прикладывают к переписке,
    /// а сотня записей с сырыми ответами сервисов в буфере нечитаема.
    private func export() {
        let moment = Date()
        // Кнопка ничего не собирает заново: оба журнала уже лежат на диске
        // готовыми, здесь их только упаковывают в конверт.
        let export = JournalExporter.make(
            settings: coordinator.settings,
            events: events,
            checks: coordinator.checkLog.all,
            at: moment
        )

        guard let data = try? export.encoded() else {
            Self.report(failure: "не удалось собрать файл журнала")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = JournalExport.fileName(at: moment)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Выгрузка журнала weto"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            Self.report(failure: error.localizedDescription)
        }
    }

    /// `NSAlert`, а не SwiftUI-алерт: в приложении с `MenuBarExtra` второй
    /// закрывает попап.
    private static func report(failure: String) {
        let alert = NSAlert()
        alert.messageText = "Журнал не выгрузился"
        alert.informativeText = failure
        alert.alertStyle = .warning
        alert.runModal()
    }
}
