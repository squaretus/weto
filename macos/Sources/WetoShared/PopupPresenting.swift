import Foundation

/// Открыть попап менюбара по внешнему поводу — нажатию на уведомление.
/// Граница: `MenuBarExtra` не отдаёт свой `NSStatusItem`, и способ его открыть живёт в приложении.
public protocol PopupPresenting: Sendable {
    @MainActor func openPopup()
}
