import Foundation

/// XPC-протокол привилегированного демона.
///
/// `performUpdate` намеренно **не принимает** ни ссылки, ни версии: демон сам
/// спрашивает GitHub и сам решает, что установить. Иначе любой процесс,
/// прошедший авторизацию, мог бы попросить root поставить произвольный пакет.
@objc public protocol WetoHelperProtocol {
    /// Версия протокола демона — клиент сверяет совместимость.
    func getHelperVersion(reply: @escaping (String) -> Void)

    /// Проверка обновления. reply: JSON `UpdateInfo` либо текст ошибки.
    func checkForUpdate(reply: @escaping (Data?, String?) -> Void)

    /// То же, но всегда с обращением к GitHub, без кэша демона.
    func checkForUpdateForced(reply: @escaping (Data?, String?) -> Void)

    /// Запускает скачивание и установку. Отвечает сразу: nil — установка начата.
    func performUpdate(reply: @escaping (String?) -> Void)

    /// Снимает сам себя: выгружает задание, удаляет свой plist, бинарник и рабочий
    /// каталог. Нужен, потому что приложение работает без прав и убрать файлы
    /// из /Library не может — иначе «полное удаление» оставляло бы демон в системе.
    func uninstallHelper(reply: @escaping (String?) -> Void)
}
