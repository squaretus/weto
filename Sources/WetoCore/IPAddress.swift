import Foundation
import Darwin

/// Разбор и проверка текстового IP-адреса.
///
/// Вынесено из `IPRange`, потому что нужно ещё и на границе гео-сервисов: строку,
/// пришедшую от ipinfo, нельзя подставлять в URL подтверждающих сервисов без проверки.
public enum IPAddress {

    public static func parse(_ text: String) -> (bytes: [UInt8], isIPv6: Bool)? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return (withUnsafeBytes(of: v4.s_addr) { Array($0) }, false)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return (withUnsafeBytes(of: v6) { Array($0) }, true)
        }
        return nil
    }

    public static func isValid(_ text: String) -> Bool {
        parse(text) != nil
    }
}
