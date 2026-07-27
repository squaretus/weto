import Foundation
import AppKit
import Darwin
import WetoCore

public protocol ProcessLocating: Sendable {

    func bundlePath(forBundleID bundleID: String) -> String?

    func allProcesses(includeArguments: Bool) -> [ProcessSnapshot]
}

extension ProcessLocating {
    public func allProcesses() -> [ProcessSnapshot] { allProcesses(includeArguments: false) }
}

public struct ProcessRegistry: ProcessLocating {

    private static let pathBufferSize = 4096

    public init() {}

    public func bundlePath(forBundleID bundleID: String) -> String? {
        NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)?
            .path
    }

    public func allProcesses(includeArguments: Bool) -> [ProcessSnapshot] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let byteCount = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, byteCount)
        }
        guard written > 0 else { return [] }

        let count = Int(written) / MemoryLayout<pid_t>.size
        var result: [ProcessSnapshot] = []
        result.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            guard let path = executablePath(pid: pid) else { continue }
            result.append(ProcessSnapshot(
                pid: pid,
                parentPID: parentPID(pid: pid),
                executablePath: path,
                arguments: includeArguments ? commandLine(pid: pid) : nil
            ))
        }
        return result
    }

    private func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(Self.pathBufferSize))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private func parentPID(pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard written == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    private func commandLine(pid: pid_t) -> String? {
        var size = Self.argumentsBufferSize
        var buffer = [CChar](repeating: 0, count: size)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }

        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        let argc = bytes.prefix(4).enumerated().reduce(Int32(0)) { acc, pair in
            acc | (Int32(pair.element) << (8 * Int32(pair.offset)))
        }
        guard argc > 0 else { return nil }

        let payload = bytes.dropFirst(MemoryLayout<Int32>.size)
        let chunks = payload.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !chunks.isEmpty else { return nil }

        return chunks.prefix(Int(argc) + 1).joined(separator: " ")
    }

    private static let argumentsBufferSize = 262_144
}
