import Testing
import Foundation
@testable import ProxyCore

@Suite struct QRCodeTests {
    @Test func generate_producesSquareMatrixAndPNG() throws {
        let qr = try #require(QRCode.generate(from: "http://192.168.1.20:8888/"))

        // QR version 1 is 21×21; anything smaller means the symbol wasn't decoded.
        #expect(qr.moduleCount >= 21)
        #expect(qr.matrix.count == qr.moduleCount)
        for row in qr.matrix { #expect(row.count == qr.moduleCount) }

        // PNG signature.
        #expect(qr.pngData.count > 0)
        #expect(Array(qr.pngData.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    /// The top-left finder pattern is a fixed 7×7 shape. Asserting it also pins
    /// orientation: `matrix[0]` must be the visual top row (not vertically mirrored,
    /// which would make the QR unscannable).
    @Test func matrix_hasCorrectlyOrientedFinderPattern() throws {
        let qr = try #require(QRCode.generate(from: "loom"))
        let m = qr.matrix

        // Top edge of the finder: 7 dark modules.
        for c in 0 ..< 7 { #expect(m[0][c], "finder top edge module \(c) should be dark") }
        // The ring is dark, its interior gap light, the 3×3 core dark.
        #expect(m[1][0])
        #expect(!(m[1][1]), "finder inner gap should be light")
        #expect(m[3][3], "finder core centre should be dark")
    }

    @Test func generate_emptyStringStillEncodes() throws {
        // Degenerate but valid — must not crash or return nil.
        let qr = try #require(QRCode.generate(from: ""))
        #expect(qr.pngData.count > 0)
    }
}
