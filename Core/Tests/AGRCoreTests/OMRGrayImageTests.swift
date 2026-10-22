import XCTest
@testable import AGRCore

final class OMRGrayImageTests: XCTestCase {
    func testPGMRoundTrip() throws {
        var img = GrayImage(width: 5, height: 3)
        img[2, 1] = 7; img[4, 2] = 200
        let back = try GrayImage.decodePGM(img.encodePGM())
        XCTAssertEqual(back, img)
    }
    func testPGMCommentsAndAscii() throws {
        let d = Data("P2\n# c\n2 2\n255\n0 10\n20 255\n".utf8)
        let img = try GrayImage.decodePGM(d)
        XCTAssertEqual(img.pixels, [0, 10, 20, 255])
    }
    func testCropClamps() {
        let img = GrayImage(width: 4, height: 4, fill: 9)
        XCTAssertEqual(img.cropped(x: -2, y: 2, width: 4, height: 9).width, 2)
        XCTAssertEqual(img.cropped(x: -2, y: 2, width: 4, height: 9).height, 2)
    }
}
