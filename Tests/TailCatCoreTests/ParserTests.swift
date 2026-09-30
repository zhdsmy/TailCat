import Foundation
import Testing
@testable import TailCatCore

@Suite struct OutputParserTests {
    @Test func parsesListenerLines() {
        let l = OutputParser.parseListener("# forwarding 127.0.0.1:2222 -> remote 22")
        #expect(l == ListenerInfo(host: "127.0.0.1", port: 2222, target: "22"))
        #expect(l?.hostPort == "127.0.0.1:2222")

        let exit = OutputParser.parseListener("# forwarding 127.0.0.1:51234 -> remote 192.168.1.10:3306")
        #expect(exit?.port == 51234)
        #expect(exit?.target == "192.168.1.10:3306")

        let v6 = OutputParser.parseListener("# forwarding [::1]:8080 -> remote 80")
        #expect(v6 == ListenerInfo(host: "::1", port: 8080, target: "80"))
        #expect(v6?.hostPort == "[::1]:8080")
    }

    @Test func ignoresOtherLines() {
        #expect(OutputParser.parse("dial remote target 22: timeout") == nil)
        #expect(OutputParser.parseListener("# forwarding nonsense") == nil)
        #expect(OutputParser.parse("") == nil)
    }

    @Test func parsesServerBanners() {
        #expect(OutputParser.parse("# 🐈 Server listening with new address: tcNEW")
                == .serverAddress(address: "tcNEW", savedKey: nil))
        #expect(OutputParser.parse(#"# 🐈 Server listening with saved key "home": tcHOME"#)
                == .serverAddress(address: "tcHOME", savedKey: "home"))
        #expect(OutputParser.parse("# 🐈 Server listening with new address: ") == nil)
    }

    @Test func parsesJSONSocksAndWarnings() {
        #expect(OutputParser.parse(#"{"listenAddr":"tcJSON"}"#) == .listenAddrJSON("tcJSON"))
        #expect(OutputParser.parse("2026/09/30 10:00:00 SOCKS running at socks5h://127.0.0.1:1080")
                == .socks("socks5h://127.0.0.1:1080"))
        #expect(OutputParser.parse("# ⚠️ WARNING: no --allow set") == .warning("no --allow set"))
    }

    @Test func parsesStatusDump() {
        let line = #"status = {"Self":{},"Peer":{"nodekey:aa":{"PublicKey":"nodekey:aa","CurAddr":"1.2.3.4:41641","Relay":"sfo","RxBytes":10,"TxBytes":20},"nodekey:bb":{"PublicKey":"nodekey:bb","CurAddr":"","Relay":"nyc"}}}"#
        guard case .peers(let peers) = OutputParser.parse(line) else {
            Issue.record("expected peers"); return
        }
        #expect(peers.map(\.publicKey) == ["nodekey:aa", "nodekey:bb"])
        #expect(peers[0].isDirect && peers[0].rxBytes == 10 && peers[0].txBytes == 20)
        #expect(!peers[1].isDirect && peers[1].relay == "nyc")
        #expect(OutputParser.parseStatusLine(#"status = {"Peer":null}"#) == [])
        #expect(OutputParser.parseStatusLine(#"status = {"Peer":[1]}"#) == nil)
        #expect(OutputParser.parseStatusLine("status = {broken") == nil)
    }

    @Test func permanentFailuresDependOnKind() {
        #expect(OutputParser.isPermanentFailure(["listen on 127.0.0.1:2222: address already in use"]))
        #expect(OutputParser.isPermanentFailure([#"mapping "x" is invalid: bad"#], kind: .forward))
        #expect(!OutputParser.isPermanentFailure(["connect: network is unreachable"]))
        #expect(OutputParser.isPermanentFailure(["FLAGS", "  --key string"], kind: .serve))
        #expect(OutputParser.isPermanentFailure(["invalid port or service to serve: \"x\""], kind: .serve))
        #expect(OutputParser.isPermanentFailure([#"invalid key "q" in --allow"#], kind: .serve))
        #expect(OutputParser.isPermanentFailure(["open /nope: no such file or directory"], kind: .recv))
        #expect(!OutputParser.isPermanentFailure(["derp: connection reset"], kind: .serve))
    }
}

@Suite struct PingTests {
    @Test func parsesDirectAndDerp() {
        let d = PingResult.parse("pong in 1.2ms via 203.0.113.7:41641")
        #expect(d == PingResult(latency: 0.0012, path: .direct(endpoint: "203.0.113.7:41641")))
        #expect(d?.shortLabel == "直连 1.2ms")
        #expect(d?.detailLabel == "直连 1.2ms (203.0.113.7:41641)")

        let r = PingResult.parse("pong in 42.1ms via DERP(sfo)")
        #expect(r?.path == .derp(region: "sfo"))
        #expect(r?.shortLabel == "中继 sfo 42ms")
        #expect(r?.detailLabel == "中继 sfo 42ms DERP(sfo)")

        let numbered = PingResult.parse("pong in 13ms via DERP(1)")
        #expect(numbered?.shortLabel == "中继 13ms")
        #expect(numbered?.detailLabel == "中继 13ms DERP(1)")

        let us = PingResult.parse("pong in 500µs via DERP(nyc)")
        #expect(us?.latency == 0.0005)
    }

    @Test(arguments: ["", "pong", "pong in x via y", "pong in 1.2ms via ", "hello"])
    func rejectsBad(_ line: String) {
        #expect(PingResult.parse(line) == nil)
    }
}

@Suite struct AddressToolsTests {
    @Test func parsesJSON() {
        let json = """
        {"ServerPublic":"nodekey:abcdef0123456789ffff","RegionID":302}
        """
        let p = AddressTools.parseJSON(json)
        #expect(p?.serverPublic == "nodekey:abcdef0123456789ffff")
        #expect(p?.regionID == 302)
        #expect(p?.summary.contains("region 302") == true)
    }

    @Test func importsBareAddressAndCLI() {
        #expect(AddressTools.importForward("tcABC123")?.address == "tcABC123")

        let cmd = AddressTools.importForward(
            "tailcat --key=work forward --bind=0.0.0.0 tcXYZ 18080:8080 3306")
        #expect(cmd?.address == "tcXYZ")
        #expect(cmd?.mappings == ["18080:8080", "3306"])
        #expect(cmd?.bind == "0.0.0.0")
        #expect(cmd?.key == "work")
    }

    @Test func rejectsGarbageImport() {
        #expect(AddressTools.importForward("") == nil)
        #expect(AddressTools.importForward("tailcat serve 22") == nil)
    }
}

@Suite struct VersionTests {
    @Test func parsesAndOrders() {
        #expect(TailcatVersion.parse("v0.7.0") == TailcatVersion(0, 7, 0))
        #expect(TailcatVersion.parse("0.8") == TailcatVersion(0, 8, 0))
        #expect(TailcatVersion.parse("v0.7.1-pre+abc\n")?.patch == 1)
        #expect(TailcatVersion.parse("devel") == nil)
        #expect(TailcatVersion(0, 7, 0) < TailcatVersion(0, 7, 1))
        #expect(TailcatVersion(0, 10, 0) > TailcatVersion(0, 9, 9))
    }

    @Test func perfNeedsNewerThan070() {
        #expect(!TailcatCapabilities.from(version: TailcatVersion(0, 7, 0)).perf)
        #expect(TailcatCapabilities.from(version: TailcatVersion(0, 7, 1)).perf)
        #expect(!TailcatCapabilities.from(version: nil).perf)
    }
}

@Suite struct FileListingTests {
    @Test func parsesLsOutput() {
        let out = """
        -rw-r--r--         1234 Sep  3 14:05 notes.txt
        drwxr-xr-x           96 Jan 12  2024 old stuff/
        -rw-------  10000000000 Dec 31 23:59 big file.iso

        garbage line
        """
        let entries = FileListing.parse(out)
        #expect(entries.count == 3)
        #expect(entries[0] == RemoteFileEntry(mode: "-rw-r--r--", size: 1234, modified: "Sep 3 14:05",
                                              name: "notes.txt", isDirectory: false))
        #expect(entries[1].isDirectory && entries[1].name == "old stuff" && entries[1].modified == "Jan 12 2024")
        #expect(entries[2].size == 10_000_000_000 && entries[2].name == "big file.iso")
    }

    @Test func pathHelpers() {
        #expect(FileListing.join(".", "a") == "a")
        #expect(FileListing.join("a/b", "c") == "a/b/c")
        #expect(FileListing.parent(of: "a/b") == "a")
        #expect(FileListing.parent(of: "a") == ".")
    }
}

@Suite struct PerfTests {
    @Test func optionArguments() {
        var o = PerfOptions()
        #expect(o.arguments() == ["--time=10s", "--timeout=10s"])
        o.proto = .udp; o.direction = .both; o.parallel = 4; o.bitrate = "100M"; o.viaDERP = true
        #expect(o.arguments() == ["--udp", "--bidir", "--parallel=4", "--time=10s", "--bitrate=100M",
                                  "--via-derp", "--timeout=10s"])
        o.direction = .download; o.bytes = "1G"
        #expect(o.arguments().contains("--reverse") && o.arguments().contains("--bytes=1G"))
        #expect(o.isValid)
        o.bytes = "-5"
        #expect(!o.isValid)
        o.bytes = "1.5K"
        #expect(o.isValid)
    }

    @Test func decodesReport() throws {
        let json = """
        {"path":{"direct":true,"endpoint":"1.2.3.4:41641","rtt":2500000},
         "pathAfter":{"direct":true,"endpoint":"1.2.3.4:41641","rtt":2600000},
         "params":{"proto":"udp","dir":"up","duration":2000000000,"streams":1,"length":1200,"interval":1000000000},
         "clientSent":{"bytes":2500000,"datagrams":2000,"duration":2000000000,
                       "intervals":[{"bytes":1250000,"datagrams":1000},{"bytes":1250000,"datagrams":1000}]},
         "serverReceived":{"bytes":2450000,"datagrams":1960,"duration":2000000000,"jitter":300000,"reordered":3},
         "rtt":{"min":2000000,"avg":3000000,"max":9000000,"count":20}}
        """
        let report = try #require(PerfReport.decode("# path: direct\n" + json))
        #expect(report.path.direct && report.path.endpoint == "1.2.3.4:41641")
        #expect(report.clientSent?.bitsPerSecond == 10_000_000)
        #expect(report.samples == [
            PerfReport.Sample(series: "发送", second: 1, mbps: 10),
            PerfReport.Sample(series: "发送", second: 2, mbps: 10),
        ])
        let summary = report.summaryLines.joined(separator: "\n")
        #expect(summary.contains("上行丢包 2.00%"))
        #expect(summary.contains("抖动 0.30ms"))
        #expect(summary.contains("乱序 3"))
        #expect(summary.contains("avg 3.0ms"))
        #expect(PerfReport.decode("not json") == nil)
    }
}

@Suite struct CLIArgumentTests {
    @Test func regionList() {
        let text = """
          1 nyc New York City
         10 sea Seattle
        bogus
        """
        #expect(DERPRegionInfo.parseList(text) == [
            DERPRegionInfo(id: 1, code: "nyc", name: "New York City"),
            DERPRegionInfo(id: 10, code: "sea", name: "Seattle"),
        ])
    }

    @Test func keyNames() {
        #expect(TailcatCLI.isValidKeyName("home-server_1.x"))
        for bad in ["", "-x", ".hidden", "a/b", "a b", "new", "中文"] {
            #expect(!TailcatCLI.isValidKeyName(bad), "\(bad)")
        }
    }

    @Test func genkeyArguments() {
        #expect(TailcatCLI.serverKeyArguments(name: "home", region: .auto, embedDERPMap: false, psk: true, force: false)
                == ["genkey", "--key=home"])
        #expect(TailcatCLI.serverKeyArguments(name: "dns", region: .nearestNow, embedDERPMap: true, psk: false, force: true)
                == ["genkey", "--key=dns", "--fixed-region", "--embed-derp-map", "--psk=false", "--force"])
        #expect(TailcatCLI.serverKeyArguments(name: "x", region: .named("sfo"), embedDERPMap: false, psk: true, force: false)
                == ["genkey", "--key=x", "--region=sfo"])
        #expect(TailcatCLI.serverKeyArguments(name: "x", region: .customHosts("d1.example,d2.example"),
                                              embedDERPMap: false, psk: true, force: false)
                == ["genkey", "--key=x", "--region=d1.example,d2.example"])
    }

    @Test func copyAndPerfArguments() {
        let settings = testSettings()
        let id = ClientIdentity(address: "tcS", key: "laptop")
        #expect(TailcatCLI.copyArguments(identity: id, sources: ["/a b", "/c"], target: "tcS:inbox",
                                         recursive: true, preserve: true, settings: settings)
                == ["--key=laptop", "cp", "-r", "-p", "/a b", "/c", "tcS:inbox"])
        #expect(TailcatCLI.remoteArg(id, path: ".") == "tcS")
        #expect(TailcatCLI.remoteArg(id, path: "docs") == "tcS:docs")
        #expect(TailcatCLI.perfArguments(identity: id, options: PerfOptions(), settings: settings)
                == ["--key=laptop", "--json", "perf", "--time=10s", "--timeout=10s", "tcS"])
    }

    @Test func sshScript() {
        let settings = testSettings()
        let id = ClientIdentity(address: "tcS")
        #expect(SSHLauncher.arguments(identity: id, user: "me", port: "", settings: settings) == ["ssh", "me@tcS"])
        #expect(SSHLauncher.arguments(identity: id, user: "", port: "2222", settings: settings)
                == ["ssh", "-p", "2222", "tcS"])
        let script = SSHLauncher.script(executable: URL(fileURLWithPath: "/opt/my tools/tailcat"),
                                        arguments: ["ssh", "me@tcS"])
        #expect(script.hasPrefix("#!/bin/sh\nrm -f \"$0\"\n"))
        #expect(script.contains("exec '/opt/my tools/tailcat' ssh me@tcS"))
        #expect(SSHLauncher.isValidPort("192.168.1.10:22"))
        #expect(!SSHLauncher.isValidPort("-oProxyCommand=x"))
    }

    @Test func shellQuote() {
        #expect(ShellQuote.quote("tcABC") == "tcABC")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("$(rm)") == "'$(rm)'")
    }

    @Test func diagnosticsMaskAddresses() {
        let addr = "tc" + String(repeating: "A1b2", count: 20)
        let masked = Diagnostics.mask("forward \(addr) 22 and tcshort")
        #expect(!masked.contains(addr))
        #expect(masked.contains("tcA1b2…(82 字符)"))
        #expect(masked.contains("tcshort"))

        let rule = TunnelRule(name: "r", address: addr, mappings: ["22"])
        let report = Diagnostics.report(appVersion: "1.0", tailcatVersion: "v0.7.0", rule: rule,
                                        commandLine: rule.cliCommand(settings: testSettings()),
                                        state: "运行中", lastPing: nil, log: ["# \(addr)"])
        #expect(!report.contains(addr))
        #expect(report.contains("v0.7.0"))
    }
}
