import Foundation
import MaestraleCore
import Testing
@testable import MaestraleModules

@Suite struct ProcessInventoryTests {
    @Test func seesItselfAndItsCounters() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let record = try #require(ProcessInventory.record(me))
        #expect(record.pid == me)
        #expect(record.uid == getuid())
        #expect(record.path?.isEmpty == false)
        #expect(record.started != nil)
        let counters = try #require(ProcessInventory.counters(me))
        #expect(counters.memory > 0)
        #expect(counters.threads > 0)
        #expect(ProcessInventory.pids().contains(me))
    }

    @Test func samplerMeasuresCPUOfABusyLoop() async throws {
        let sampler = ProcessSampler(commands: FakeCommands())
        _ = sampler.sample()
        let deadline = Date().addingTimeInterval(0.3)
        var x = 0.0
        while Date() < deadline { x += sin(x) + 1 }
        let activities = sampler.sample()
        let me = try #require(activities.first { $0.process.pid == ProcessInfo.processInfo.processIdentifier })
        #expect(me.cpu > 0.2)
        #expect(x > 0)
    }

    @Test func nettopAndLsofParsers() {
        let totals = ProcessSampler.parseNettop(",bytes_in,bytes_out,\nlaunchd.1,0,0,\nmDNSResponder.455,11198055,4963379,\nbad line\n")
        #expect(totals[455] == NetworkTotals(bytesIn: 11_198_055, bytesOut: 4_963_379))
        #expect(totals.count == 2)

        let sockets = Sockets.parse("""
        p655
        cControlCenter
        f10
        PTCP
        n*:7000
        TST=LISTEN
        TQR=0
        f12
        PUDP
        n*:5353
        p900
        cminer
        f3
        PTCP
        n192.168.1.5:52000->45.67.89.10:3333
        TST=ESTABLISHED
        """)
        #expect(sockets.count == 3)
        #expect(sockets[0].listensOnAllInterfaces)
        #expect(sockets[0].localPort == 7000)
        #expect(sockets[1].state == nil)
        #expect(sockets[2].remote?.host == "45.67.89.10")
        #expect(sockets[2].remote?.port == 3333)

        let table = Sockets.parseTable("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nrapportd    661 nico   11u  IPv4 0xd537      0t0  TCP *:49470 (LISTEN)\nminer 900 root 3u IPv4 0x1 0t0 TCP 10.0.0.2:5000->1.2.3.4:4444 (ESTABLISHED)\n")
        #expect(table.count == 2)
        #expect(table[0].isListening)
        #expect(table[1].remote?.port == 4444)
    }
}

@Suite struct ProcessesCheckTests {
    func activity(pid: Int32, name: String, path: String?, cpu: Double, uid: uid_t = getuid()) -> ProcessActivity {
        ProcessActivity(process: ProcessRecord(pid: pid, parent: 1, uid: uid, name: name, path: path, started: Date()),
                        cpu: cpu, memory: 1_000_000, diskReadPerSecond: 0, diskWritePerSecond: 0,
                        networkInPerSecond: 0, networkOutPerSecond: 0, threads: 2)
    }

    @Test func minerHiddenProcessAndFakeSystemNameAreDangers() throws {
        let home = try TempHome(); defer { home.remove() }
        let busy = home.url.appendingPathComponent("Library/.hidden/xmrig").path
        let fake = home.url.appendingPathComponent("Applications/kernel_task").path
        let fine = "/Applications/Safari.app/Contents/MacOS/Safari"
        try home.executable("Library/.hidden/xmrig")
        try home.executable("Applications/kernel_task")
        let sample = [activity(pid: 900, name: "xmrig", path: busy, cpu: 0.95), activity(pid: 901, name: "kernel_task", path: fake, cpu: 0.0),
                      activity(pid: 902, name: "Safari", path: fine, cpu: 0.9), activity(pid: 903, name: "gone", path: "/tmp/gone-\(UUID())", cpu: 0.0)]
        let sockets = [SocketInfo(pid: 900, command: "xmrig", proto: "TCP", name: "10.0.0.5:5000->45.67.89.10:3333", state: "ESTABLISHED"),
                       SocketInfo(pid: 901, command: "kernel_task", proto: "TCP", name: "*:4444", state: "LISTEN")]
        let signatures = FakeSignatures([busy: .unsigned, fake: .adHoc, fine: .apple])
        let check = ProcessesCheck(samples: [sample, sample, sample], sockets: sockets)
        let findings = check.run(home.context(signatures: signatures))
        let byPid = Dictionary(uniqueKeysWithValues: findings.map { ($0.id, $0) })

        let miner = try #require(byPid["process|900|\(busy)"])
        #expect(miner.severity == .danger)
        #expect(miner.reasons.contains("Gira da una cartella nascosta"))
        #expect(miner.reasons.contains { $0.hasPrefix("Usa il 95% di un core") })
        #expect(miner.reasons.contains { $0.contains("mining pool") })
        #expect(miner.action == .terminateProcess(pid: 900))

        let fakeTask = try #require(byPid["process|901|\(fake)"])
        #expect(fakeTask.severity == .danger)
        #expect(fakeTask.reasons.contains("Ha il nome di un processo di sistema ma non viene dal sistema"))
        #expect(fakeTask.reasons.contains { $0.hasPrefix("In ascolto sulla rete su 4444") })

        #expect(byPid["process|902|\(fine)"] == nil) // Apple, busy: fine
        let gone = try #require(findings.first { $0.title.hasPrefix("gone") })
        #expect(gone.severity == .danger)
        #expect(gone.reasons.contains { $0.contains("cancellato") })
    }

    @Test func developerToolingInHiddenFolderIsInformational() throws {
        let home = try TempHome(); defer { home.remove() }
        let python = try home.executable(".pyenv/versions/3.12/bin/python3.12").path
        let check = ProcessesCheck(samples: [[activity(pid: 7, name: "python3.12", path: python, cpu: 0.1)]], sockets: [])
        let findings = check.run(home.context(signatures: FakeSignatures(fallback: .adHoc)))
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .info)
    }

    @Test func spikeInOneSampleIsNotSustained() throws {
        let home = try TempHome(); defer { home.remove() }
        let path = "/bin/ls"
        let samples = [[activity(pid: 5, name: "Tool", path: path, cpu: 0.9)], [activity(pid: 5, name: "Tool", path: path, cpu: 0.1)],
                       [activity(pid: 5, name: "Tool", path: path, cpu: 0.95)]]
        let check = ProcessesCheck(samples: samples, sockets: [])
        let findings = check.run(home.context(signatures: FakeSignatures(fallback: .signed(team: "T", notarized: true))))
        #expect(findings.isEmpty)
    }

    @Test func liveScanRunsQuickly() throws {
        let home = try TempHome(); defer { home.remove() }
        let started = Date()
        let findings = ProcessesCheck(intervals: 1, interval: 0.2).run(home.context(signatures: FakeSignatures(fallback: .apple)))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(findings.allSatisfy { $0.category == .process })
    }
}
