import Foundation
import Darwin

/// Режим терминала, снятый с устройства: путь к нему и `termios` как есть.
public struct TerminalMode: Equatable, Sendable {
    /// Устройство (`e_tdev` процесса) — по нему режим и возвращается.
    public let device: Int32
    /// `/dev/ttys006` — для журнала и ошибок.
    public let path: String
    /// Байты `termios`: сама структура не `Sendable`, а возвращать её нужно целиком —
    /// флаги, управляющие символы и скорость.
    public let attributes: Data

    public init(device: Int32, path: String, attributes: Data) {
        self.device = device
        self.path = path
        self.attributes = attributes
    }
}

public enum TerminalModeError: Error, Equatable, Sendable {
    case noDevice(Int32)
    case open(path: String, errno: Int32)
    case read(path: String, errno: Int32)
    case write(path: String, errno: Int32)
}

/// Снять режим терминала цели до паузы и вернуть его, когда цель снова впереди.
///
/// Под tmux шелл переднего задания удержать остановленным нельзя: сервер tmux следит
/// за своими детьми-шеллами панелей и тут же продолжает остановленного. Шелл, проснувшись
/// посреди паузы, видит остановку своего задания, печатает `suspended (signal)`, забирает
/// терминал и переключает его режим. Проверено вживую на macOS и Linux — zsh и bash под
/// tmux теряют передний план при любых паузах между сигналами, а на голом pty (Terminal,
/// iTerm без tmux) порядок «шелл первым» его сохраняет. Программа в сыром режиме, сама его
/// не восстанавливающая (`claude`), после `fg` рисуется, но клавиши до неё не доходят:
/// терминал так и остаётся в режиме шелла.
/// Вернуть его может любой процесс того же пользователя — устройство его, а SIGTTOU
/// грозит только фоновым членам сессии этого терминала, которой weto не принадлежит.
public protocol TerminalModeKeeping: Sendable {
    func capture(device: Int32) -> Result<TerminalMode, TerminalModeError>
    func restore(_ mode: TerminalMode) -> Result<Void, TerminalModeError>
}

public struct TerminalModeKeeper: TerminalModeKeeping {

    public init() {}

    public func capture(device: Int32) -> Result<TerminalMode, TerminalModeError> {
        guard let path = Self.path(of: device) else { return .failure(.noDevice(device)) }
        return Self.withDescriptor(path) { fd in
            var attributes = termios()
            guard tcgetattr(fd, &attributes) == 0 else { return .failure(.read(path: path, errno: errno)) }
            let bytes = withUnsafeBytes(of: &attributes) { Data($0) }
            return .success(TerminalMode(device: device, path: path, attributes: bytes))
        }
    }

    public func restore(_ mode: TerminalMode) -> Result<Void, TerminalModeError> {
        guard mode.attributes.count == MemoryLayout<termios>.size else {
            return .failure(.write(path: mode.path, errno: EINVAL))
        }
        return Self.withDescriptor(mode.path) { fd in
            var attributes = termios()
            withUnsafeMutableBytes(of: &attributes) { _ = mode.attributes.copyBytes(to: $0) }
            // TCSANOW, а не TCSAFLUSH: введённое пользователем после `fg` не выбрасываем.
            guard tcsetattr(fd, TCSANOW, &attributes) == 0 else {
                return .failure(.write(path: mode.path, errno: errno))
            }
            return .success(())
        }
    }

    /// `/dev/ttys006` по номеру устройства. `devname` ищет среди символьных устройств.
    static func path(of device: Int32) -> String? {
        guard device != 0, device != -1 else { return nil }
        guard let name = devname(device, S_IFCHR) else { return nil }
        let base = String(cString: name)
        guard !base.isEmpty, base != "??" else { return nil }
        return "/dev/" + base
    }

    /// `O_NOCTTY`: открытый терминал не должен стать управляющим для weto.
    /// `O_NONBLOCK`: открытие не ждёт несущей у модемных линий.
    private static func withDescriptor<T>(
        _ path: String,
        _ body: (Int32) -> Result<T, TerminalModeError>
    ) -> Result<T, TerminalModeError> {
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return .failure(.open(path: path, errno: errno)) }
        defer { close(fd) }
        return body(fd)
    }
}
