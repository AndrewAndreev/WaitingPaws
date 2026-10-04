import XCTest
@testable import WaitingPawsCore

/// Fragments of real specs from miot-spec.org (2026-10-04).
final class CameraModesTests: XCTestCase {
    /// These tests check the Russian texts (the default language of the app's first users).
    override func setUp() {
        super.setUp()
        CoreLanguage.current = .ru
    }

    private let c302n = """
    {"type": "urn:miot-spec-v2:device:camera:0000A01C:xiaomi-c302n:1:0000D070", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:xiaomi-c302n:1:0000D070", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 3, "type": "urn:miot-spec-v2:property:night-shot:00000057:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "Off"}, {"value": 1, "description": "On"}, {"value": 2, "description": "Auto"}]}, {"iid": 4, "type": "urn:miot-spec-v2:property:image-rollover:00000058:xiaomi-c302n:1:0000D070", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 270, 90]}, {"iid": 5, "type": "urn:miot-spec-v2:property:time-watermark:00000087:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 7, "type": "urn:miot-spec-v2:property:glimmer-full-color:00000089:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 9, "type": "urn:miot-spec-v2:property:human-tracking:000001A8:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 11, "type": "urn:miot-spec-v2:property:recording-mode:0000008B:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "All Record "}, {"value": 1, "description": "Motion Record"}, {"value": 2, "description": "No Record"}]}, {"iid": 12, "type": "urn:miot-spec-v2:property:power-frequency:0000036B:xiaomi-c302n:1:0000D070", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "auto"}, {"value": 1, "description": "50"}, {"value": 2, "description": "60"}]}]}, {"iid": 4, "type": "urn:miot-spec-v2:service:indicator-light:00007803:xiaomi-c302n:1:0000D070", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}]}, {"iid": 8, "type": "urn:miot-spec-v2:service:ai-detection:000078C8:xiaomi-c302n:1:0000D070", "properties": [{"iid": 22, "type": "urn:miot-spec-v2:property:pet-tracking:000003E4:xiaomi-c302n:1:0000D070", "format": "bool", "access": ["read", "write", "notify"]}]}]}
    """

    private let chuangmiV6 = """
    {"type": "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-v6:1", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:chuangmi-v6:1", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:chuangmi-v6:1", "format": "bool", "access": ["write"]}, {"iid": 2, "type": "urn:miot-spec-v2:property:night-shot:00000057:chuangmi-v6:1", "format": "uint8", "access": ["read", "write"], "value-list": [{"value": 0, "description": "On"}, {"value": 1, "description": "Off"}, {"value": 2, "description": "Auto"}]}, {"iid": 3, "type": "urn:miot-spec-v2:property:image-rollover:00000058:chuangmi-v6:1", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 180, 180]}, {"iid": 6, "type": "urn:miot-spec-v2:property:wdr-mode:00000088:chuangmi-v6:1", "format": "bool", "access": ["read", "write"]}]}]}
    """

    private let isaHlc7 = """
    {"type": "urn:miot-spec-v2:device:camera:0000A01C:isa-hlc7:2", "services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:isa-hlc7:1", "properties": [{"iid": 2, "type": "urn:miot-spec-v2:property:image-rollover:00000058:isa-hlc7:1", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 360, 180]}, {"iid": 3, "type": "urn:miot-spec-v2:property:night-shot:00000057:isa-hlc7:1", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "Off"}, {"value": 1, "description": "On"}, {"value": 2, "description": "Auto"}]}]}]}
    """

    private func modes(_ json: String) throws -> [CameraModeOption] {
        try MiotSpec.cameraModes(fromSpec: Data(json.utf8))
    }

    func testC302OffersPictureSettingsInDisplayOrderAndSkipsTheRest() throws {
        let options = try modes(c302n)
        XCTAssertEqual(options.map(\.setting), [
            .nightShot, .glimmerFullColor, .imageRollover, .timeWatermark, .powerFrequency,
            .humanTracking, .petTracking, .indicatorLight,
        ])
        // Camera power and SD recording are not offered.
        XCTAssertFalse(options.contains { $0.property == MiotPropertyID(siid: 2, piid: 1) })
        XCTAssertFalse(options.contains { $0.property == MiotPropertyID(siid: 2, piid: 11) })
        XCTAssertEqual(options.first { $0.setting == .indicatorLight }?.property, MiotPropertyID(siid: 4, piid: 1))
        XCTAssertEqual(options.first { $0.setting == .petTracking }?.property, MiotPropertyID(siid: 8, piid: 22))
    }

    func testNightModeValuesFollowTheSpecNotTheNumber() throws {
        let c302 = try XCTUnwrap(modes(c302n).first { $0.setting == .nightShot })
        XCTAssertEqual(c302.property, MiotPropertyID(siid: 2, piid: 3))
        XCTAssertEqual(c302.choices, [.init(value: 2, title: "Авто"), .init(value: 1, title: "Ночной"), .init(value: 0, title: "Обычный")])

        // On chuangmi 0 means "On".
        let v6 = try XCTUnwrap(modes(chuangmiV6).first { $0.setting == .nightShot })
        XCTAssertEqual(v6.choices, [.init(value: 2, title: "Авто"), .init(value: 0, title: "Ночной"), .init(value: 1, title: "Обычный")])
        XCTAssertEqual(v6.text(for: .int(0)), "Ночной")
    }

    func testRolloverAndPowerFrequencyChoices() throws {
        let options = try modes(c302n)
        XCTAssertEqual(options.first { $0.setting == .imageRollover }?.choices.map(\.title), ["Без поворота", "90°", "180°", "270°"])
        XCTAssertEqual(options.first { $0.setting == .powerFrequency }?.choices.map(\.title), ["Авто", "50 Гц", "60 Гц"])
        // 0…360 step 180: 360° is 0° again.
        XCTAssertEqual(try modes(isaHlc7).first { $0.setting == .imageRollover }?.choices.map(\.value), [0, 180])
    }

    func testWriteOnlyPropertiesAreSkipped() throws {
        XCTAssertEqual(try modes(chuangmiV6).map(\.setting), [.nightShot, .wdr, .imageRollover])
    }

    func testSpecTypeTakesTheNewestVersion() throws {
        let index = """
        {"instances": [
          {"model": "chuangmi.camera.v6", "version": 1, "type": "urn:miot-spec-v2:device:camera:0000A01C:chuangmi-v6:1"},
          {"model": "xiaomi.camera.c302n", "version": 1, "type": "urn:old"},
          {"model": "xiaomi.camera.c302n", "version": 2, "type": "urn:new"}
        ]}
        """
        XCTAssertEqual(try MiotSpec.specType(forModel: "xiaomi.camera.c302n", inIndex: Data(index.utf8)), "urn:new")
        XCTAssertNil(try MiotSpec.specType(forModel: "unknown.camera.x", inIndex: Data(index.utf8)))
    }

    func testValuesDecodeFromBoolsAndNumbers() throws {
        let values = try JSONDecoder().decode([MiotValue].self, from: Data("[true, 0, 2, 1.0]".utf8))
        XCTAssertEqual(values, [.bool(true), .int(0), .int(2), .int(1)])
        XCTAssertTrue(MiotValue.int(1).isOn)
        XCTAssertEqual(MiotValue.bool(true).number, 1)
    }

    func testCameraErrorCodes() {
        XCTAssertNoThrow(try XiaomiCameraError.check(0))
        XCTAssertNoThrow(try XiaomiCameraError.check(1))
        XCTAssertThrowsError(try XiaomiCameraError.check(-704042011)) { XCTAssertEqual($0 as? XiaomiCameraError, .offline) }
        XCTAssertThrowsError(try XiaomiCameraError.check(-704220043)) {
            XCTAssertEqual($0 as? XiaomiCameraError, .failed(code: -704220043))
        }
    }
}
