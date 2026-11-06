import XCTest

/// Drives SpringBoard to reach a Live Activity: STEPS="lock;sleep:1;wake;shot:/tmp/x.png;tap:Вернулись".
final class TapperUITests: XCTestCase {
    func testRun() throws {
        let env = ProcessInfo.processInfo.environment
        let steps = (env["STEPS"] ?? "").split(separator: ";").map(String.init)
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            print("[tapper] \(step)")
            switch parts[0] {
            case "lock", "wake":
                XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
            case "home":
                XCUIDevice.shared.press(.home)
            case "sleep":
                Thread.sleep(forTimeInterval: Double(arg) ?? 1)
            case "nc":
                let start = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
                let end = sb.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
                start.press(forDuration: 0.05, thenDragTo: end)
            case "island":
                sb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.028)).press(forDuration: 1.2)
            case "tap":
                let button = sb.buttons[arg]
                if button.waitForExistence(timeout: 6) {
                    print("[tapper] found «\(arg)» at \(button.frame)")
                    button.tap()
                } else {
                    print(sb.debugDescription)
                    XCTFail("no button «\(arg)»")
                }
            case "swipeleft":
                let match = sb.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
                if match.waitForExistence(timeout: 4) {
                    print("[tapper] swiping «\(arg)» at \(match.frame)")
                    match.swipeLeft()
                } else {
                    XCTFail("nothing like «\(arg)»")
                }
            case "tapany":
                let match = sb.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
                if match.waitForExistence(timeout: 4) {
                    print("[tapper] tapping «\(arg)» at \(match.frame)")
                    match.tap()
                } else {
                    XCTFail("nothing like «\(arg)»")
                }
            case "appswipeup":
                let app = XCUIApplication(bundleIdentifier: arg.isEmpty ? "su.comrade.waitingpaws" : arg)
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                start.press(forDuration: 0.05, thenDragTo: end)
            case "shot":
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: arg))
            case "apptap":
                // apptap:<label>: the first element of Waiting Paws whose label contains it.
                let app = XCUIApplication(bundleIdentifier: "su.comrade.waitingpaws")
                let match = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", arg)).firstMatch
                if match.waitForExistence(timeout: 6) {
                    print("[tapper] app tap «\(arg)» at \(match.frame)")
                    match.tap()
                } else {
                    print(app.debugDescription)
                    XCTFail("nothing like «\(arg)» in the app")
                }
            case "appdump":
                print(XCUIApplication(bundleIdentifier: "su.comrade.waitingpaws").debugDescription)
            case "dump":
                print(sb.debugDescription)
            default:
                XCTFail("unknown step \(step)")
            }
        }
    }
}
