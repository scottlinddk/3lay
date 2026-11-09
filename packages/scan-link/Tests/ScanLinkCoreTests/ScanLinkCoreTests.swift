import XCTest
@testable import ScanLinkCore

final class ScanLinkCoreTests: XCTestCase {
    func testCodeValidation() {
        XCTAssertTrue(LanProtocol.isValidCode("123456"))
        XCTAssertFalse(LanProtocol.isValidCode("12345"))
        XCTAssertFalse(LanProtocol.isValidCode("12345a"))
        XCTAssertFalse(LanProtocol.isValidCode("１２３４５６"))  // full-width digits
    }

    func testAcceptedFilenames() {
        for ok in ["a.stl", "A.OBJ", "x.ply", "scan.usdz"] { XCTAssertTrue(LanProtocol.isAcceptedFilename(ok), ok) }
        for bad in ["a.zip", "a", "a.stl.exe", ".stl"] { XCTAssertFalse(LanProtocol.isAcceptedFilename(bad), bad) }
    }

    func testCaptureArchivesAreSeparateFromMeshes() {
        XCTAssertTrue(LanProtocol.isCaptureArchive("Scan.ZIP"))
        XCTAssertTrue(LanProtocol.isAcceptedUpload("Scan.zip"))
        XCTAssertTrue(LanProtocol.isAcceptedUpload("a.usdz"))
        XCTAssertFalse(LanProtocol.isAcceptedUpload("a.exe"))
        XCTAssertGreaterThan(LanProtocol.maxBytes(for: "a.zip"), LanProtocol.maxBytes(for: "a.usdz"))
    }

    func testHelloFromOlderMacHasNoCaptureLimit() throws {
        let old = #"{"service":"threelaymacos","version":1,"name":"Old","maxBytes":1,"extensions":["stl"]}"#
        XCTAssertNil(try JSONDecoder().decode(LanHello.self, from: Data(old.utf8)).maxCaptureBytes)
    }

    func testUploadPathEncodesOneSegmentAndStripsDirectories() {
        XCTAssertEqual(LanProtocol.uploadPath(for: "my scan.usdz"), "/upload/my%20scan.usdz")
        XCTAssertEqual(LanProtocol.uploadPath(for: "../../etc/x.stl"), "/upload/x.stl")
        XCTAssertEqual(LanProtocol.uploadPath(for: "a?b#c.stl"), "/upload/a%3Fb%23c.stl")
    }

    func testParseEndpoint() {
        XCTAssertEqual(LanEndpoint.parse("192.168.1.5"), LanEndpoint(name: "192.168.1.5", host: "192.168.1.5", port: 8765))
        XCTAssertEqual(LanEndpoint.parse(" http://192.168.1.5:9000/ ")?.port, 9000)
        XCTAssertEqual(LanEndpoint.parse("studio-mac.local")?.host, "studio-mac.local")
        XCTAssertEqual(LanEndpoint.parse("192.168.1.5", name: "Studio")?.name, "Studio")
    }

    func testParseRejectsNonLocalAndMalformed() {
        for bad in ["8.8.8.8", "example.com", "172.32.0.1", "https://192.168.1.5", "", "192.168.1.5:0",
                    "192.168.1.5:99999", "a b", "192.168.1.5:80:81", "10.0.0.1/../x"] {
            XCTAssertNil(LanEndpoint.parse(bad), bad)
        }
    }

    func testLocalNetworkRanges() {
        for ok in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.0.9", "169.254.1.1", "127.0.0.1", "100.100.1.1", "mac.local", "mac"] {
            XCTAssertTrue(LanEndpoint(name: "", host: ok, port: 1).isLocalNetwork, ok)
        }
        for bad in ["172.15.0.1", "100.63.0.1", "1.1.1.1", "mac.example.com"] {
            XCTAssertFalse(LanEndpoint(name: "", host: bad, port: 1).isLocalNetwork, bad)
        }
    }

    func testBaseURL() {
        XCTAssertEqual(LanEndpoint(name: "", host: "10.0.0.2", port: 8765).baseURL?.absoluteString, "http://10.0.0.2:8765")
        XCTAssertEqual(LanEndpoint(name: "", host: "fe80::1", port: 80).baseURL?.absoluteString, "http://[fe80::1]:80")
    }

    func testHelloRoundTripCarriesNoSecret() throws {
        let data = try JSONEncoder().encode(LanHello(name: "Studio"))
        let hello = try JSONDecoder().decode(LanHello.self, from: data)
        XCTAssertEqual(hello.service, "threelaymacos")
        XCTAssertEqual(hello.extensions, LanProtocol.acceptedExtensions)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("code"))
    }

    func testClientRefusesPublicAddressesBeforeAnyRequest() async {
        let client = LanClient(endpoint: LanEndpoint(name: "x", host: "8.8.8.8", port: 80), code: "123456")
        do { _ = try await client.hello(); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? LanError, .notLocalNetwork)
        }
    }
}
