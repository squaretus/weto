import Foundation
import Observation
import WetoCore

@Observable
@MainActor
public final class EventLogStore {

    private static let key = "eventLog"

    public private(set) var events: [KillEvent] = []

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([KillEvent].self, from: data) {
            events = decoded
        }
    }

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: Constants.userDefaultsSuite) ?? .standard)
    }

    public var preview: [KillEvent] {
        Array(events.prefix(Constants.eventLogPreviewCount))
    }

    public func record(_ event: KillEvent) {
        events.insert(event, at: 0)
        if events.count > Constants.eventLogCapacity {
            events.removeLast(events.count - Constants.eventLogCapacity)
        }
        persist()
    }

    public func clear() {
        events.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
