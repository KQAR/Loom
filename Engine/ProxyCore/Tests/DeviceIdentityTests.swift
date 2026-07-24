import Testing
@testable import LoomProxyCore
import LoomSharedModels

@Suite struct DeviceIdentityTests {
    // MARK: Display name: disambiguated fallback (aliases layered on in the UI)

    @Test func displayName_usesPlatformAndIPSuffix() {
        let device = SourceDevice(ip: "192.168.1.37", kind: .lan, platform: "iOS", client: "Safari")
        #expect(device.ipSuffix == ".37")
        #expect(device.displayName == "iOS .37") // two same-type devices stay distinct by suffix
    }

    @Test func displayName_localIsThisMac() {
        let device = SourceDevice(ip: "127.0.0.1", kind: .local, platform: "macOS", client: "Chrome")
        #expect(device.displayName == "This Mac")
    }

    @Test(arguments: [
        ("127.0.0.1", SourceDevice.Kind.local),
        ("::1", .local),
        ("192.168.1.20", .lan),
    ])
    func kindClassification(ip: String, expected: SourceDevice.Kind) {
        #expect(SourceDevice.kind(forIP: ip) == expected)
    }
}
