import XCTest
import Security
import CoreMedia
import CoreVideo
@testable import EasyConnKit

final class ProtocolTests: XCTestCase {
    func testPxcFrameRoundTripAndMagic() throws {
        let f = PxcFrame(cmd: PxcCmd.mdnsRespond, payload: Data("{\"a\":1}".utf8))
        let bytes = [UInt8](f.encoded())
        XCTAssertEqual(bytes.count, 16 + 7)
        XCTAssertEqual(bytes.le32(at: 0), 0x70000010)
        XCTAssertEqual(bytes.le32(at: 4), 23)
        XCTAssertEqual(bytes.le32(at: 8), 0x70000010 ^ 23)
        XCTAssertEqual(bytes.le32(at: 12), 0)
        var p = PxcFrameParser()
        XCTAssertEqual(try p.feed(f.encoded()), [f])
    }

    func testParserHandlesSplitAndCoalescedChunks() throws {
        let a = PxcFrame(cmd: 0x10000), b = PxcFrame(cmd: 0x10010, payload: Data("hi".utf8))
        let all = a.encoded() + b.encoded()
        var p = PxcFrameParser()
        var got = [PxcFrame]()
        for byte in all { got += try p.feed(Data([byte])) }
        XCTAssertEqual(got, [a, b])
        var p2 = PxcFrameParser()
        XCTAssertEqual(try p2.feed(all), [a, b])
    }

    func testParserRejectsBadMagic() {
        var bad = [UInt8](PxcFrame(cmd: 5).encoded())
        bad[8] ^= 0xff
        var p = PxcFrameParser()
        XCTAssertThrowsError(try p.feed(Data(bad)))
    }

    func testReqBaseRoundTrip() {
        let r = ReqBase(cmdType: 17, token: 0, body: Data([1, 2, 3]))
        var p = ReqBaseParser()
        XCTAssertEqual(p.feed(r.encoded()), [r])
        XCTAssertEqual([UInt8](r.encoded()).prefix(4), [17, 0, 3, 0])
    }

    func testCaptureConfigRoundsDownTo16() {
        var body = Data()
        body.appendLE(Int16(800)); body.appendLE(Int16(951)); body.appendLE(Int32(30)); body.appendLE(Int32(2))
        body.append(Data(count: 20))
        let cc = CaptureConfig(body: body)!
        XCTAssertEqual(cc.width, 800); XCTAssertEqual(cc.height, 951)
        let (reply, w, h) = cc.reply()
        XCTAssertEqual(w, 800); XCTAssertEqual(h, 944)   // matches the CFDL26 example in the notes
        XCTAssertEqual(reply.count, 9)
        let r = [UInt8](reply)
        XCTAssertEqual(r.le32(at: 0), 2); XCTAssertEqual(r.le16(at: 4), 800); XCTAssertEqual(r.le16(at: 6), 944)
        var cc2 = cc; cc2.height = 386
        XCTAssertEqual(cc2.reply().height, 384)          // CFDL16: 386 -> 384
    }

    func testQrParse() {
        let qr = QrData.parse("http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9&ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk&mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457")
        XCTAssertEqual(qr?.ssid, "CFMOTO-f46457")
        XCTAssertEqual(qr?.pwd, "59a9cddc94")
        XCTAssertEqual(qr?.action, 9)
        XCTAssertEqual(qr?.supportsAp, true)
        XCTAssertEqual(qr?.supportsP2p, true)
        XCTAssertNil(QrData.parse("hello"))
    }

    func testRsaSpkiParsesAndSignatureIsRawPkcs1Type1() throws {
        let keys = try RsaKeys()
        // The SPKI we hand the dash must be importable as a public key by a standard parser.
        let der = Data(base64Encoded: keys.publicKeyBase64)!
        XCTAssertEqual(der.count, 162)                       // 1024-bit RSA SPKI
        XCTAssertEqual(Array(der.prefix(4)), [0x30, 0x81, 0x9f, 0x30])
        let pkcs1 = der.suffix(from: der.startIndex + 22)    // strip the SPKI header
        var err: Unmanaged<CFError>?
        let imported = SecKeyCreateWithData(Data(pkcs1) as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &err)
        XCTAssertNotNil(imported, "\(String(describing: err))")

        // "Encrypt with private key" = 00 01 FF..FF 00 <data> once the public operation is undone.
        let sig = Data(base64Encoded: try keys.signHuid("6GUVA2C00100055"))!
        let block = SecKeyCreateEncryptedData(keys.publicKey, .rsaEncryptionRaw, sig as CFData, &err) as Data?
        let b = [UInt8](block ?? Data())
        XCTAssertEqual(b.count, 128)
        XCTAssertEqual(Array(b.prefix(2)), [0x00, 0x01])
        let sep = b.dropFirst(2).firstIndex(of: 0x00)!
        XCTAssertTrue(b[2..<sep].allSatisfy { $0 == 0xff })
        XCTAssertEqual(String(decoding: b[(sep + 1)...], as: UTF8.self), "6GUVA2C00100055")
    }

    func testClientInfoReplyHasRequiredKeys() throws {
        let keys = try RsaKeys()
        let data = PhoneIdentity().clientInfoReply(huid: "ABC", keys: keys)
        let o = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for k in ["pxcVersion", "phoneUUID", "package", "pubkey", "encryptedHUID", "supportH264IFrame", "supportFunction"] {
            XCTAssertNotNil(o[k], k)
        }
        XCTAssertEqual(o["package"] as? String, "com.cfmoto.cfmotointernational")
        XCTAssertFalse((o["encryptedHUID"] as! String).isEmpty)
    }

    func testTimeSyncEchoesRealStampAndFillsEpoch() {
        var req = Data(count: 16)
        req.append(Data("2026-10-31 12:34:56.789000000".utf8))
        XCTAssertEqual(huTimeSyncAck(request: req), req)
        let empty = huTimeSyncAck(request: Data())
        XCTAssertEqual(empty.count, 45)
        XCTAssertFalse(String(decoding: empty.dropFirst(16), as: UTF8.self).hasPrefix("1970"))
    }

    func testEncoderProducesAnnexBKeyframeWithSpsPps() throws {
        let enc = try H264Encoder(width: 800, height: 384)
        let got = expectation(description: "key frame")
        got.assertForOverFulfill = false
        var first: (Data, Bool)?
        enc.onAccessUnit = { au, key in if first == nil { first = (au, key); got.fulfill() } }
        let src = TestPatternSource()
        for i in 0..<10 {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 800, 384, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
            src.render(into: pb!, at: Date())
            enc.encode(pb!, pts: CMTime(value: Int64(i), timescale: 30))
        }
        wait(for: [got], timeout: 5)
        let (au, key) = first!
        XCTAssertTrue(key)
        let b = [UInt8](au)
        XCTAssertEqual(Array(b.prefix(4)), [0, 0, 0, 1])
        var nals = [UInt8]()
        for i in 0..<(b.count - 4) where b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 { nals.append(b[i+4] & 0x1f) }
        XCTAssertEqual(Array(nals.prefix(3)), [7, 8, 5])     // SPS, PPS, IDR
        enc.invalidate()
    }
}

final class LocalNetworkTests: XCTestCase {
    func testCandidatesPutTheNetworksOwnGatewayFirstWithoutDuplicates() {
        let w = LocalNetwork.Wifi(interface: "en0", ip: "192.168.43.77", mask: "255.255.255.0", gatewayGuess: "192.168.43.1")
        XCTAssertEqual(LocalNetwork.probeCandidates(explicit: nil, wifi: w),
                       ["192.168.43.1", "192.168.3.1", "192.168.0.1", "192.168.49.1"])
        let same = LocalNetwork.Wifi(interface: "en0", ip: "192.168.0.50", mask: "255.255.255.0", gatewayGuess: "192.168.0.1")
        XCTAssertEqual(LocalNetwork.probeCandidates(explicit: nil, wifi: same), ["192.168.0.1", "192.168.3.1", "192.168.49.1"])
        XCTAssertEqual(LocalNetwork.probeCandidates(explicit: "10.0.0.1", wifi: nil).first, "10.0.0.1")
    }

    func testDottedQuad() {
        XCTAssertEqual(LocalNetwork.dotted(0xC0A8_2B01), "192.168.43.1")
    }
}
