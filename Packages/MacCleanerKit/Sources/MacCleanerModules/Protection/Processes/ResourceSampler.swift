import Darwin
import Foundation
import MacCleanerCore

/// What a process did between two samples.
public struct ProcessActivity: Identifiable, Sendable, Hashable {
    public let process: ProcessRecord
    /// 1.0 = one core busy for the whole interval.
    public let cpu: Double
    public let memory: UInt64
    public let diskReadPerSecond: Double
    public let diskWritePerSecond: Double
    public let networkInPerSecond: Double
    public let networkOutPerSecond: Double
    public let threads: Int
    public var id: Int32 { process.pid }

    public init(process: ProcessRecord, cpu: Double, memory: UInt64, diskReadPerSecond: Double, diskWritePerSecond: Double,
                networkInPerSecond: Double, networkOutPerSecond: Double, threads: Int) {
        self.process = process
        self.cpu = cpu
        self.memory = memory
        self.diskReadPerSecond = diskReadPerSecond
        self.diskWritePerSecond = diskWritePerSecond
        self.networkInPerSecond = networkInPerSecond
        self.networkOutPerSecond = networkOutPerSecond
        self.threads = threads
    }
}

/// Bytes in and out per process, from `nettop`.
public struct NetworkTotals: Sendable, Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64
}

/// Samples every process; CPU, disk and network are rates between two calls.
/// Keep one instance for the length of a screen.
public final class ProcessSampler: @unchecked Sendable {
    private var previous: [Int32: (counters: ProcessCounters, network: NetworkTotals?, time: Date)] = [:]
    private let commands: any CommandRunner
    private let lock = NSLock()

    public init(commands: any CommandRunner = SystemCommands()) {
        self.commands = commands
    }

    public func sample(now: Date = Date()) -> [ProcessActivity] {
        let network = Self.parseNettop(commands.run("/usr/bin/nettop", ["-x", "-P", "-L", "1", "-J", "bytes_in,bytes_out"]))
        lock.lock(); defer { lock.unlock() }
        var next: [Int32: (ProcessCounters, NetworkTotals?, Date)] = [:]
        var activities: [ProcessActivity] = []
        for record in ProcessInventory.all() {
            guard let counters = ProcessInventory.counters(record.pid) else { continue }
            let totals = network[record.pid]
            next[record.pid] = (counters, totals, now)
            guard let last = previous[record.pid] else { continue }
            let seconds = max(now.timeIntervalSince(last.time), 0.001)
            func rate(_ new: UInt64, _ old: UInt64) -> Double { new >= old ? Double(new - old) / seconds : 0 }
            activities.append(ProcessActivity(
                process: record,
                cpu: rate(counters.cpuNanoseconds, last.counters.cpuNanoseconds) / 1_000_000_000,
                memory: counters.memory,
                diskReadPerSecond: rate(counters.diskRead, last.counters.diskRead),
                diskWritePerSecond: rate(counters.diskWritten, last.counters.diskWritten),
                networkInPerSecond: rate(totals?.bytesIn ?? 0, last.network?.bytesIn ?? 0),
                networkOutPerSecond: rate(totals?.bytesOut ?? 0, last.network?.bytesOut ?? 0),
                threads: counters.threads))
        }
        previous = next
        return activities
    }

    /// `nettop -x -P -L 1 -J bytes_in,bytes_out`: CSV rows "name.pid,in,out,".
    public static func parseNettop(_ text: String) -> [Int32: NetworkTotals] {
        var result: [Int32: NetworkTotals] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { continue }
            result[pid] = NetworkTotals(bytesIn: bytesIn, bytesOut: bytesOut)
        }
        return result
    }
}

/// One socket of a process, from `lsof`.
public struct SocketInfo: Sendable, Hashable {
    public let pid: Int32
    public let command: String
    public let proto: String        // TCP or UDP
    public let name: String         // "*:7000" or "192.168.1.5:52000->1.2.3.4:443"
    public let state: String?       // LISTEN, ESTABLISHED…
    public var isListening: Bool { state == "LISTEN" }
    public var listensOnAllInterfaces: Bool { isListening && name.hasPrefix("*:") }
    public var remote: (host: String, port: Int)? {
        guard let arrow = name.range(of: "->") else { return nil }
        let remote = String(name[arrow.upperBound...])
        guard let colon = remote.lastIndex(of: ":"), let port = Int(remote[remote.index(after: colon)...]) else { return nil }
        return (String(remote[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
    }
    public var localPort: Int? {
        let local = name.components(separatedBy: "->").first ?? name
        guard let colon = local.lastIndex(of: ":") else { return nil }
        return Int(local[local.index(after: colon)...])
    }
}

public enum Sockets {
    /// Sockets of the processes the user may inspect; with `text` from the
    /// privileged evidence, every user's.
    public static func list(commands: any CommandRunner) -> [SocketInfo] {
        parse(commands.run("/usr/sbin/lsof", ["-i", "-n", "-P", "-F", "pcnPT"]))
    }

    /// `lsof -F pcnPT`: "p<pid>" starts a process, then per socket "P<proto>",
    /// "n<name>" and "TST=<state>" lines.
    public static func parse(_ text: String) -> [SocketInfo] {
        var sockets: [SocketInfo] = []
        var pid: Int32 = 0
        var command = ""
        var proto = ""
        var name: String?
        var state: String?
        func flush() {
            if let current = name { sockets.append(SocketInfo(pid: pid, command: command, proto: proto, name: current, state: state)) }
            name = nil; state = nil
        }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p": flush(); pid = Int32(value) ?? 0
            case "c": command = value
            case "f": flush()
            case "P": proto = value
            case "n": name = value
            case "T": if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return sockets
    }

    /// The plain table format (`lsof -i -n -P`), as the privileged evidence prints it.
    public static func parseTable(_ text: String) -> [SocketInfo] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard columns.count >= 9, let pid = Int32(columns[1]) else { return nil }
            let state = columns.count > 9 ? columns[9].trimmingCharacters(in: CharacterSet(charactersIn: "()")) : nil
            return SocketInfo(pid: pid, command: columns[0], proto: columns[7], name: columns[8], state: state)
        }
    }
}
