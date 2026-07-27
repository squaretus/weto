import Foundation

/// Процесс в том виде, в каком его отдаёт `proc_listallpids` + `proc_pidpath`.
///
/// `arguments` — полная командная строка из `KERN_PROCARGS2`, нужна для целей,
/// запускаемых интерпретатором: у Node- или Python-скрипта `executablePath`
/// указывает на сам интерпретатор, и матчинг по нему выкосил бы все процессы
/// этого интерпретатора разом. `nil`, если аргументы не запрашивались или
/// недоступны (чужой пользователь, защищённый процесс).
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: Int32
    /// PID родителя. Нужен, чтобы гасить потомков цели: приложение может
    /// породить хелперы и внешние утилиты, которые сами по себе целями не являются,
    /// но продолжат работать и ходить в сеть после смерти родителя.
    public let parentPID: Int32
    public let executablePath: String
    public let arguments: String?

    public init(
        pid: Int32,
        parentPID: Int32 = 0,
        executablePath: String,
        arguments: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.executablePath = executablePath
        self.arguments = arguments
    }
}
