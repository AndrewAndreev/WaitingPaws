import XCTest
@testable import WaitingPawsCore

/// Who is on the other end of the link: ids, kinds and models, and that builds on both sides of the change still
/// understand each other.
final class SyncDeviceTests: XCTestCase {
    func testHostInfoCarriesIdKindAndModelThroughTXT() {
        let info = SyncHostInfo(name: "MacBook Air", cameraTitle: "Прихожая", cameraReady: true,
                                id: "7F1C", platform: SyncPlatform.mac.rawValue, model: "MacBook Air")
        let parsed = SyncHostInfo(name: "MacBook Air", txt: info.txt)
        XCTAssertEqual(parsed, info)
        XCTAssertEqual(parsed.device, SyncDevice(id: "7F1C", name: "MacBook Air", kind: .mac, model: "MacBook Air"))
        XCTAssertEqual(parsed.device.symbolName, "laptopcomputer")
    }

    func testHostWithoutIdIsKnownByNameAndIsAMac() {
        // TXT of a build before ids: the name stands in, and only Macs advertised then.
        let txt = ["v": "2", "cam": "Прихожая", "ready": "1", "session": "0"]
        let device = SyncHostInfo(name: "Mac mini", txt: txt).device
        XCTAssertEqual(device.id, "name:Mac mini")
        XCTAssertEqual(device.kind, .mac)
        XCTAssertEqual(device.kindTitle, "Mac")
        XCTAssertEqual(device.symbolName, "desktopcomputer")
    }

    func testWindowsHostAndUnknownKinds() {
        let pc = SyncHostInfo(name: "DESKTOP-7Q", txt: ["v": "2", "id": "A1", "os": "windows"]).device
        XCTAssertEqual(pc.kind, .windows)
        XCTAssertEqual(pc.symbolName, "pc")
        XCTAssertEqual(pc.modelTitle, pc.kindTitle, "no model: the kind stands in")

        let future = SyncHostInfo(name: "Box", txt: ["v": "2", "id": "B2", "os": "toaster"]).device
        XCTAssertNil(future.kind, "a kind this build doesn't know is not taken for a Mac")
        XCTAssertEqual(future.symbolName, "questionmark.square.dashed")
    }

    func testHelloFromAnOlderIPhoneIsAnIPhone() throws {
        // A v2 hello before `platform` and `model` existed.
        let json = #"{"hello":{"_0":{"deviceID":"D1","deviceName":"iPhone","publicKey":"AAEC","protocolVersion":2}}}"#
        guard case .hello(let hello) = try SyncMessage.decode(Data(json.utf8)) else { return XCTFail("not a hello") }
        XCTAssertEqual(hello.device, SyncDevice(id: "D1", name: "iPhone", kind: .iphone, model: ""))
        XCTAssertEqual(hello.device.modelTitle, "iPhone")
        XCTAssertTrue(hello.device.nameIsModel)
    }

    func testNewHelloAndWelcomeStillReadByOlderBuilds() throws {
        /// The fields older builds decode (unknown keys are ignored by `Decodable`).
        struct OldHello: Decodable { var deviceID: String; var deviceName: String; var publicKey: Data; var protocolVersion: Int }
        struct OldWelcome: Decodable { var hostName: String; var go2rtcPort: Int; var username: String; var password: String; var addresses: [String] }
        struct Wrapped<T: Decodable>: Decodable { var _0: T }

        let hello = SyncHello(deviceID: "D1", deviceName: "iPhone Тани", publicKey: Data([1, 2]),
                              platform: SyncPlatform.iphone.rawValue, model: "iPhone 16")
        let helloJSON = try JSONSerialization.jsonObject(with: SyncMessage.hello(hello).encoded()) as! [String: Any]
        let helloBody = try JSONSerialization.data(withJSONObject: helloJSON["hello"]!)
        let old = try SyncProtocol.decoder().decode(Wrapped<OldHello>.self, from: helloBody)._0
        XCTAssertEqual(old.deviceName, "iPhone Тани")
        XCTAssertEqual(old.protocolVersion, SyncProtocol.version)

        let welcome = SyncWelcome(hostName: "MacBook Pro", go2rtcPort: 11984, username: "u", password: "p",
                                  addresses: ["192.168.1.5"], hostID: "H1", platform: "mac", model: "MacBook Pro")
        let body = try SyncProtocol.encoder().encode(welcome)
        XCTAssertEqual(try SyncProtocol.decoder().decode(OldWelcome.self, from: body).hostName, "MacBook Pro")
        XCTAssertEqual(try SyncProtocol.decoder().decode(SyncWelcome.self, from: body), welcome)

        // …and a welcome from an older Mac reads here without the new fields.
        let oldBody = #"{"hostName":"Mac","go2rtcPort":1,"username":"","password":"","addresses":[]}"#
        let parsed = try SyncProtocol.decoder().decode(SyncWelcome.self, from: Data(oldBody.utf8))
        XCTAssertNil(parsed.hostID)
        XCTAssertNil(parsed.platform)
    }

    func testModelNames() {
        XCTAssertEqual(DeviceModelName.iPhone("iPhone17,3"), "iPhone 16")
        XCTAssertEqual(DeviceModelName.iPhone("iPhone16,1"), "iPhone 15 Pro")
        XCTAssertNil(DeviceModelName.iPhone("iPhone99,1"))

        XCTAssertEqual(DeviceModelName.mac(productName: "MacBook Pro (16-inch, Nov 2023)\0", identifier: "Mac15,7"), "MacBook Pro")
        XCTAssertEqual(DeviceModelName.mac(productName: "Mac mini (2024)", identifier: "Mac16,10"), "Mac mini")
        XCTAssertEqual(DeviceModelName.mac(productName: nil, identifier: "MacBookAir10,1"), "MacBook Air")
        XCTAssertEqual(DeviceModelName.mac(productName: nil, identifier: "iMacPro1,1"), "iMac Pro")
        XCTAssertEqual(DeviceModelName.mac(productName: nil, identifier: "Mac15,7"), "Mac")

        XCTAssertNil(SyncDevice(id: "1", name: "MacBook Pro — Андрей", kind: .mac, model: "MacBook Pro").distinctModel)
        XCTAssertEqual(SyncDevice(id: "2", name: "Кухня", kind: .mac, model: "Mac mini").distinctModel, "Mac mini")
        XCTAssertEqual(SyncDevice(id: "3", name: "DESKTOP-7QK", kind: .windows, model: "").distinctModel, SyncPlatform.windows.title)

        XCTAssertEqual(SyncPlatform.mac.symbolName(model: "Mac mini"), "macmini")
        XCTAssertEqual(SyncPlatform.mac.symbolName(model: "iMac"), "desktopcomputer")
    }
}
