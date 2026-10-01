import Testing
@testable import TailCatCore

@Suite struct CopyOptionsTests {
    @Test func preserveAddsCpFlag() {
        let identity = ClientIdentity(address: "tcEXAMPLE", key: "laptop")
        let settings = testSettings()

        #expect(TailcatCLI.copyArguments(identity: identity, sources: ["tcEXAMPLE:docs"],
                                          target: "/tmp/", recursive: true, preserve: false, settings: settings)
                == ["--key=laptop", "cp", "-r", "tcEXAMPLE:docs", "/tmp/"])
        #expect(TailcatCLI.copyArguments(identity: identity, sources: ["tcEXAMPLE:docs"],
                                          target: "/tmp/", recursive: true, preserve: true, settings: settings)
                == ["--key=laptop", "cp", "-r", "-p", "tcEXAMPLE:docs", "/tmp/"])
    }
}
