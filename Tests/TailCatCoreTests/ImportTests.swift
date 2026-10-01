import Foundation
import Testing
@testable import TailCatCore

@Suite struct ForwardImportTests {
    @Test func parsesShellQuotedCLIOutputWithoutExecutingIt() throws {
        let settings = testSettings()
        let rule = TunnelRule(name: "x", address: "tcEXAMPLE", key: "alice's key",
                              mappings: ["2222:22"], bind: "0.0.0.0")
        let imported = try AddressTools.parseForward(rule.cliCommand(settings: settings)).get()

        #expect(imported.address == rule.address)
        #expect(imported.key == rule.key)
        #expect(imported.bind == rule.bind)
        #expect(imported.mappings == rule.mappings)
        #expect(imported.isCommand)

        let injection = AddressTools.parseForward("tailcat forward tcEXAMPLE '2222:22; touch /tmp/should-not-exist'")
        #expect(injection == .failure(.invalidMapping))
    }

    @Test func retainsBrowserFlagAndUsesCLIdefaultBind() throws {
        let imported = try AddressTools.parseForward("tailcat forward --open-browser tcEXAMPLE 80").get()
        #expect(imported.openBrowser)
        #expect(imported.bind == "127.0.0.1")

        var rule = TunnelRule(name: "web", address: "old", mappings: ["81"], openBrowser: false)
        imported.apply(to: &rule, remotes: [])
        #expect(rule.address == "tcEXAMPLE")
        #expect(rule.mappings == ["80"])
        #expect(rule.openBrowser)
        #expect(rule.bind == "127.0.0.1")
    }

    @Test func quotedKeyPathCanBeImportedAndSaved() throws {
        let original = TunnelRule(name: "web", address: "tcEXAMPLE", key: "/tmp/Demo Keys/alice's key.private.json",
                                  mappings: ["80"])
        let imported = try AddressTools.parseForward(original.cliCommand(settings: testSettings())).get()
        var rule = TunnelRule(name: "web")
        imported.apply(to: &rule, remotes: [])
        #expect(rule.validate().isEmpty)
        #expect(rule.key == original.key)
        var remote = Remote(name: "box")
        imported.apply(to: &remote)
        #expect(remote.validate().isEmpty)
        for invalid in ["-flag", "line\nbreak", "null\0byte"] {
            rule.key = invalid
            remote.key = invalid
            #expect(rule.validate().contains(.invalidKey))
            #expect(remote.validate().contains(.invalidKey))
        }
    }

    @Test func reportsMalformedQuotesMappingsAndUnsupportedDerpmap() {
        #expect(AddressTools.parseForward("tailcat forward tcEXAMPLE '80") == .failure(.invalidQuoting))
        #expect(AddressTools.parseForward("tailcat forward tcEXAMPLE 70000:80") == .failure(.invalidMapping))
        let derp = AddressTools.parseForward("tailcat --derpmap-url=https://derp.example/map.json forward tcEXAMPLE 80")
        #expect(derp == .failure(.unsupportedOption("--derpmap-url")))
        if case .failure(let error) = derp {
            #expect(error.errorDescription?.contains("--derpmap-url") == true)
        }
    }

    @Test func rejectsShellExpansionAndUnquotedOperatorsButKeepsLiterals() throws {
        for command in [
            "tailcat --key=$HOME forward tcEXAMPLE 80",
            "tailcat --key=\"$(whoami)\" forward tcEXAMPLE 80",
            "tailcat --key=`whoami` forward tcEXAMPLE 80",
            "tailcat forward tcEXAMPLE 80; echo done",
            "tailcat forward tcEXAMPLE 80 | cat",
            "tailcat forward tcEXAMPLE 80 &",
            "tailcat forward tcEXAMPLE 80 > result",
            "tailcat forward (tcEXAMPLE) 80",
        ] {
            #expect(AddressTools.parseForward(command) == .failure(.unsupportedShellSyntax))
        }

        let singleQuoted = try AddressTools.parseForward("tailcat --key='$HOME;|&<>()`whoami`$(whoami)' forward tcEXAMPLE 80").get()
        #expect(singleQuoted.key == "$HOME;|&<>()`whoami`$(whoami)")

        let escaped = try AddressTools.parseForward(#"tailcat --key=\$HOME forward tcEXAMPLE 80"#).get()
        #expect(escaped.key == "$HOME")
        let escapedInDoubleQuotes = try AddressTools.parseForward(#"tailcat --key="\$HOME" forward tcEXAMPLE 80"#).get()
        #expect(escapedInDoubleQuotes.key == "$HOME")
    }

    @Test func matchesRemoteByAddressAndKeyAndClearsUnmatchedKey() throws {
        let keyed = Remote(name: "work", address: "tcEXAMPLE", key: "work")
        let ruleImport = try AddressTools.parseForward("tailcat --key=work forward tcEXAMPLE 80").get()
        var rule = TunnelRule(name: "new")
        let selectedID = ruleImport.apply(to: &rule, remotes: [keyed])
        #expect(selectedID == keyed.id)
        #expect(rule.remoteID == keyed.id)
        #expect(rule.address.isEmpty && rule.key.isEmpty)

        let bare = try AddressTools.parseForward("tcEXAMPLE").get()
        var existing = TunnelRule(name: "existing", remoteID: keyed.id, key: "work", mappings: ["81"])
        #expect(bare.apply(to: &existing, remotes: [keyed]) == nil)
        #expect(existing.remoteID == nil)
        #expect(existing.address == "tcEXAMPLE" && existing.key.isEmpty)
        #expect(existing.mappings == ["81"])
    }

    @Test func remoteImportAlsoClearsKeyWhenOnlyAddressWasPasted() throws {
        var remote = Remote(name: "box", address: "old", key: "work")
        let bare = try AddressTools.parseForward("tcEXAMPLE").get()
        bare.apply(to: &remote)
        #expect(remote.address == "tcEXAMPLE")
        #expect(remote.key.isEmpty)
    }

    @Test func duplicateGetsNewIdentityAndDoesNotAutoStart() {
        let original = TunnelRule(id: UUID(), name: "web", address: "tcEXAMPLE", key: "work",
                                  mappings: ["80"], autoStart: true)
        let copy = original.duplicate()
        #expect(copy.id != original.id)
        #expect(copy.name == "web 副本")
        #expect(!copy.autoStart)
        #expect(copy.address == original.address && copy.key == original.key)
        #expect(copy.mappings == original.mappings)
    }

    @Test func openBrowserRequiresExactlyOneMapping() {
        let valid = TunnelRule(name: "web", address: "tcEXAMPLE", mappings: ["80"], openBrowser: true)
        #expect(!valid.validate().contains(.openBrowserNeedsOneMapping))

        var zero = valid
        zero.mappings = []
        #expect(zero.validate().contains(.openBrowserNeedsOneMapping))
        var many = valid
        many.mappings.append("81")
        #expect(many.validate().contains(.openBrowserNeedsOneMapping))
    }
}
