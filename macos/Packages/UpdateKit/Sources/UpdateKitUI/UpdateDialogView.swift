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

    /// Отступ окна и шаг ряда кнопок — числа вёрстки, а не украшение: по ним
    /// считается минимальная ширина, при которой подписи не обрезаются.
    static let padding: CGFloat = 18
    static let rowSpacing: CGFloat = 8

    /// Наименьшая ширина окна, при которой ряд кнопок помещается целиком.
    ///
    /// Кнопкам запрещено сжиматься, поэтому окно уже этого значения не обрезает
    /// текст — оно обрезает саму кнопку. Число подбирается не на глаз: тема
    /// обязана сверить свою ширину с замером живых контролов, иначе смена
    /// подписи или стиля пилюли тихо выносит последнюю кнопку за край.
    public static func minimumWidth(fittingButtons widths: [CGFloat]) -> CGFloat {
        guard let first = widths.first else { return 0 }

        // Между соседями — распорка: два промежутка `HStack` плюс её minLength.
        let perGap = rowSpacing * 3
        return widths.dropFirst().reduce(first) { $0 + perGap + $1 } + padding * 2
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
        .padding(Self.padding)
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
    ///
    /// Свободная ширина делится между кнопками поровну — по распорке на каждый
    /// промежуток. С одной распоркой ряд читался как две группы: слева «Пропустить
    /// версию», справа прижатые друг к другу «Напомнить позже» и «Обновить».
    @ViewBuilder
    private func buttons(model: UpdateDialogModel) -> some View {
        HStack(alignment: .center, spacing: Self.rowSpacing) {
            if model.showsChoiceButtons {
                theme.secondaryButton(controller.strings.skip) { controller.skipCurrentVersion() }
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: Self.rowSpacing)

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
                    Spacer(minLength: Self.rowSpacing)

                    theme.primaryButton(controller.strings.install) { controller.install() }
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if model.showsReleasePageButton {
                Spacer(minLength: Self.rowSpacing)
                theme.secondaryButton(controller.strings.openReleasePage) {
                    controller.openReleasePage()
                }
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
