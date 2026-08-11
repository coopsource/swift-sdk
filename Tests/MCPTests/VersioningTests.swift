import Testing

@testable import MCP

@Suite("Version Negotiation Tests")
struct VersioningTests {
    @Test("Client requests latest supported version")
    func testClientRequestsLatestSupportedVersion() {
        let clientVersion = Version.latest
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests older supported version")
    func testClientRequestsOlderSupportedVersion() {
        let clientVersion = "2024-11-05"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == "2024-11-05")
    }

    @Test("Client requests unsupported version")
    func testClientRequestsUnsupportedVersion() {
        let clientVersion = "2023-01-01"  // An unsupported version
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests empty version string")
    func testClientRequestsEmptyVersionString() {
        let clientVersion = ""
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Client requests garbage version string")
    func testClientRequestsGarbageVersionString() {
        let clientVersion = "not-a-version"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == Version.latest)
    }

    @Test("Server's supported versions correctly defined")
    func testServerSupportedVersions() {
        #expect(Version.supported.contains("2026-07-28"))
        #expect(Version.supported.contains("2025-11-25"))
        #expect(Version.supported.contains("2025-06-18"))
        #expect(Version.supported.contains("2025-03-26"))
        #expect(Version.supported.contains("2024-11-05"))
        #expect(Version.supported.count == 5)
    }

    @Test("Server's latest version is correct")
    func testServerLatestVersion() {
        #expect(Version.latest == "2025-11-25")
    }

    @Test("Client requests new 2025-11-25 version")
    func testClientRequests2025_11_25Version() {
        let clientVersion = "2025-11-25"
        let negotiatedVersion = Version.negotiate(clientRequestedVersion: clientVersion)
        #expect(negotiatedVersion == "2025-11-25")
    }

    @Test(
        "Initialization negotiation preserves every initialization-based revision",
        arguments: ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    )
    func testEveryInitializationVersion(version: String) {
        #expect(Version.negotiate(clientRequestedVersion: version) == version)
    }

    @Test("Initialization negotiation never selects a per-request-metadata revision")
    func testPerRequestVersionIsNotAnInitializationVersion() {
        #expect(
            Version.negotiate(clientRequestedVersion: Version.perRequestMetadataVersion)
                == Version.latestInitializationVersion
        )
    }
}
