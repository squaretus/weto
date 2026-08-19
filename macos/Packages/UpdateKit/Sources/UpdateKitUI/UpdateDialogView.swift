import SwiftUI
import UpdateKitCore
import UpdateKit

/// Одно окно на два состояния: предложение обновиться и ход установки.
/// Что показывать — решает `UpdateDialogModel`, вёрстка только рисует.
public struct UpdateDialogView: View {

    @Bindable private var controller: UpdateController
    private let theme: UpdateTheme

    public init(controller: UpdateController, theme: UpdateTheme) {
        self.controller = controller
        self.theme = theme
    }

    public var body: some View {
        let model = controller.dialogModel

        // Ряд кнопок идёт во всю ширину окна, а не внутри колонки с текстом:
        // в колонке ему остаётся ширина минус иконка, и подписи обрезались
        // в «Проп…» и «Обн…».
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                theme.icon
                    .resizable()
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 10) {
                    Text(model.title)
                        .font(theme.titleFont)
                        .foregroundStyle(theme.text)

                    Text(model.detail)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if controller.progress.isInFlight {
                        progressBar(fraction: model.fraction)
                    }

                    if model.showsChoiceButtons {
                        Toggle(
                            controller.strings.autoInstallToggle,
                            isOn: $controller.isAutoInstallEnabled
                        )
                            .font(theme.bodyFont)
                            .foregroundStyle(theme.secondaryText)
                            .toggleStyle(.checkbox)
                            .tint(theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            buttons(model: model)
        }
        .padding(18)
        .frame(width: theme.width, alignment: .leading)
        .background(theme.background)
    }

    @ViewBuilder
    private func progressBar(fraction: Double?) -> some View {
        if let fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(theme.accent)
        } else {
            // installer прогресса не отдаёт — полоса честно неопределённая.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(theme.accent)
        }
    }

    /// Кнопкам запрещено сжиматься: подпись целиком или окно шире, но не «Обн…».
    ///
    /// Выравнивание по центру задано явно: ряд смешивает пилюли и кнопку с меню,
    /// и на умолчании они вставали по разным линиям.
    @ViewBuilder
    private func buttons(model: UpdateDialogModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if model.showsChoiceButtons {
                theme.secondaryButton(controller.strings.skip) { controller.skipCurrentVersion() }
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                theme.menuButton(
                    controller.strings.remindLater,
                    RemindInterval.allCases.enumerated().map { index, interval in
                        UpdateMenuItem(
                            id: index,
                            title: controller.strings.remindTitle(for: interval),
                            action: { controller.remindLater(interval) }
                        )
                    }
                )
                    .fixedSize(horizontal: true, vertical: false)

                if model.canInstall {
                    theme.primaryButton(controller.strings.install) { controller.install() }
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if model.showsReleasePageButton {
                Spacer(minLength: 8)
                theme.secondaryButton(controller.strings.openReleasePage) {
                    controller.openReleasePage()
                }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
