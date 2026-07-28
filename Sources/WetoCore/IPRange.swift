import Foundation
import Darwin

public struct IPRange: Equatable, Hashable, Codable, Sendable {

    public let networkBytes: [UInt8]
    public let prefixLength: Int
    public let isIPv6: Bool

    public let text: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        guard let (bytes, isV6) = Self.parseAddress(String(parts[0])) else { return nil }

        let maxPrefix = isV6 ? 128 : 32
        var prefix = maxPrefix
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed >= 0, parsed <= maxPrefix else { return nil }
            prefix = parsed
        }

        self.networkBytes = Self.masked(bytes, prefixLength: prefix)
        self.prefixLength = prefix
        self.isIPv6 = isV6
        self.text = trimmed
    }

    public func contains(_ ip: String) -> Bool {
        guard let (bytes, isV6) = Self.parseAddress(ip.trimmingCharacters(in: .whitespaces)),
              isV6 == isIPv6
        else { return false }
        return Self.masked(bytes, prefixLength: prefixLength) == networkBytes
    }

    private static func parseAddress(_ string: String) -> ([UInt8], Bool)? {
        IPAddress.parse(string).map { ($0.bytes, $0.isIPv6) }
    }

    private static func masked(_ bytes: [UInt8], prefixLength: Int) -> [UInt8] {
        var result = bytes
        for index in result.indices {
            let bitsBefore = index * 8
            if prefixLength >= bitsBefore + 8 { continue }
            if prefixLength <= bitsBefore {
                result[index] = 0
            } else {
                let keep = prefixLength - bitsBefore
                result[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        return result
    }
}
