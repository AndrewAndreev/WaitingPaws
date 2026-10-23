import Foundation
import WaitingPawsCore

extension AppModel {
    /// The camera on screen turns (the second one too: the modes are read for the camera shown) and there is a go2rtc
    /// to send the steps to (ours, or the linked Mac's).
    var canPanTilt: Bool {
        #if DEBUG
        if cameraModes.isDemoCamera { return cameraModes.panTilt }
        #endif
        return cameraModes.panTilt && panTiltTarget != nil
    }

    var panTiltTarget: CameraPanTilt.Target? {
        guard let server = activeServer, !shownStreamName.isEmpty else { return nil }
        return CameraPanTilt.Target(server: server, stream: shownStreamName)
    }
}
