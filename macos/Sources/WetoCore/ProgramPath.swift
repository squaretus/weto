import Foundation

/// Пути программ как текст: диск не читается.
public enum ProgramPath {

    /// Та же программа другой версии: пути различаются только номером версии внутри
    /// каталогов, а имя файла то же.
    ///
    /// Каталог многих программ называется по версии, и стабильного пути над ним нет:
    /// node под nvm живёт в `~/.nvm/versions/node/v20.11.0`, обновляемое Squirrel —
    /// в `app-1.0.9`, приложение Microsoft Store — в `Claude_6.28899.6.0_x64__…`.
    /// Обновление кладёт программу в соседний каталог и удаляет прежний, и цель,
    /// записанная прежним путём, молча переставала совпадать с чем-либо: разрешать
    /// её заново нечем, файла больше нет.
    ///
    /// Версия — первая в сегменте серия чисел через точку, не меньше двух
    /// (`6.28899.6.0`, `1.0.10`, `2024.1`); всё до и после неё обязано совпасть.
    /// Одиночное число версией не считается (`Python311`, ревизия snap `123`), имя файла
    /// сравнивается точно: `python3.12` рядом с `python3.11` — другая программа.
    ///
    /// Правило общее с `path_text::same_program_across_versions` в `weto-core`
    /// (Linux и Windows); регистр, как и во всём сопоставлении на macOS, различается.
    public static func sameProgramAcrossVersions(_ left: String, _ right: String) -> Bool {
        guard left.hasPrefix("/"), right.hasPrefix("/") else { return false }
        let left = left.split(separator: "/", omittingEmptySubsequences: true)
        let right = right.split(separator: "/", omittingEmptySubsequences: true)
        // Почти все сравнения — с чужими процессами: несовпавшее имя файла отсеивает
        // их без разбора каталогов.
        guard let leftFile = left.last, left.count == right.count, leftFile == right.last else {
            return false
        }
        return zip(left, right).allSatisfy { a, b in
            if a == b { return true }
            guard let a = versionSplit(a), let b = versionSplit(b) else { return false }
            return a.head == b.head && a.tail == b.tail
        }
    }

    /// Сегмент вокруг первой серии чисел через точку (не меньше двух чисел):
    /// то, что до неё, и то, что после. `nil` — версии в сегменте нет.
    static func versionSplit<S: StringProtocol>(_ segment: S) -> (head: Substring, tail: Substring)? {
        let bytes = Array(segment.utf8)
        func isDigit(_ index: Int) -> Bool {
            index < bytes.count && bytes[index] >= UInt8(ascii: "0") && bytes[index] <= UInt8(ascii: "9")
        }
        var index = 0
        while index < bytes.count {
            guard isDigit(index) else {
                index += 1
                continue
            }
            let start = index
            var numbers = 0
            while true {
                while isDigit(index) { index += 1 }
                numbers += 1
                guard index < bytes.count, bytes[index] == UInt8(ascii: "."), isDigit(index + 1) else { break }
                index += 1
            }
            if numbers >= 2 {
                // Цифры и точка — ASCII: обе границы приходятся на границы символов.
                let text = Substring(segment)
                let utf8 = text.utf8
                let lower = utf8.index(utf8.startIndex, offsetBy: start)
                let upper = utf8.index(utf8.startIndex, offsetBy: index)
                return (text[..<lower], text[upper...])
            }
        }
        return nil
    }
}
