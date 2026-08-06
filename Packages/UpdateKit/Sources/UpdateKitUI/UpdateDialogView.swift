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
                    Toggle(controller.strings.autoInstallToggle, isOn: $controller.isAutoInstallEnabled)
                        .font(theme.bodyFont)
                        .foregroundStyle(theme.secondaryText)
                        .toggleStyle(.checkbox)
                        .tint(theme.accent)
                }

                buttons(model: model)
                    .padding(.top, 4)
            }
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

    @ViewBuilder
    private func buttons(model: UpdateDialogModel) -> some View {
        HStack(spacing: 8) {
            if model.showsChoiceButtons {
                theme.secondaryButton(controller.strings.skip) { controller.skipCurrentVersion() }

                Spacer(minLength: 12)

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

                if model.canInstall {
                    theme.primaryButton(controller.strings.install) { controller.install() }
                }
            }

            if model.showsReleasePageButton {
                Spacer(minLength: 12)
                theme.secondaryButton(controller.strings.openReleasePage) {
                    controller.openReleasePage()
                }
            }
        }
    }
}
