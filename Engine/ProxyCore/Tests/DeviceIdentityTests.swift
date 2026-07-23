import XCTest
@testable import ProxyCore
import SharedModels

final class DeviceIdentityTests: XCTestCase {
    // MARK: - Display name: disambiguated fallback (aliases layered on in the UI)

    func test_displayName_usesPlatformAndIPSuffix() {
        let device = SourceDevice(ip: "192.168.1.37", kind: .lan, platform: "iOS", client: "Safari")
        XCTAssertEqual(device.ipSuffix, ".37")
        XCTAssertEqual(device.displayName, "iOS .37") // two same-type devices stay distinct by suffix
    }

    func test_displayName_localIsThisMac() {
        let device = SourceDevice(ip: "127.0.0.1", kind: .local, platform: "macOS", client: "Chrome")
        XCTAssertEqual(device.displayName, "This Mac")
    }

    func test_kindClassification() {
        XCTAssertEqual(SourceDevice.kind(forIP: "127.0.0.1"), .local)
        XCTAssertEqual(SourceDevice.kind(forIP: "::1"), .local)
        XCTAssertEqual(SourceDevice.kind(forIP: "192.168.1.20"), .lan)
    }
}
