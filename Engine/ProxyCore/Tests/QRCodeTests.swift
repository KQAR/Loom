import XCTest
@testable import ProxyCore

final class QRCodeTests: XCTestCase {
    func test_generate_producesSquareMatrixAndPNG() throws {
        let qr = try XCTUnwrap(QRCode.generate(from: "http://192.168.1.20:8888/"))

        // QR version 1 is 21×21; anything smaller means the symbol wasn't decoded.
        XCTAssertGreaterThanOrEqual(qr.moduleCount, 21)
        XCTAssertEqual(qr.matrix.count, qr.moduleCount)
        for row in qr.matrix { XCTAssertEqual(row.count, qr.moduleCount) }

        // PNG signature.
        XCTAssertGreaterThan(qr.pngData.count, 0)
        XCTAssertEqual(Array(qr.pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// The top-left finder pattern is a fixed 7×7 shape. Asserting it also pins
    /// orientation: `matrix[0]` must be the visual top row (not vertically mirrored,
    /// which would make the QR unscannable).
    func test_matrix_hasCorrectlyOrientedFinderPattern() throws {
        let qr = try XCTUnwrap(QRCode.generate(from: "loom"))
        let m = qr.matrix

        // Top edge of the finder: 7 dark modules.
        for c in 0 ..< 7 { XCTAssertTrue(m[0][c], "finder top edge module \(c) should be dark") }
        // The ring is dark, its interior gap light, the 3×3 core dark.
        XCTAssertTrue(m[1][0])
        XCTAssertFalse(m[1][1], "finder inner gap should be light")
        XCTAssertTrue(m[3][3], "finder core centre should be dark")
    }

    func test_generate_emptyStringStillEncodes() throws {
        // Degenerate but valid — must not crash or return nil.
        let qr = try XCTUnwrap(QRCode.generate(from: ""))
        XCTAssertGreaterThan(qr.pngData.count, 0)
    }
}
