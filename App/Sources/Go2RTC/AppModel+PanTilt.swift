import Foundation
import WaitingPawsCore

extension AppModel {
    /// The camera on screen turns and there is a go2rtc to send the steps to (ours, or the linked Mac's). Only the
    /// first camera: its modes are the ones read.
    var canPanTilt: Bool {
        if isShowingSecondCamera { return false }
        #if DEBUG
        if cameraModes.isDemoCamera { return cameraModes.panTilt }
        #endif
        return cameraModes.panTilt && panTiltTarget != nil
    }

    var panTiltTarget: CameraPanTilt.Target? {
        guard let server = activeServer, !activeStreamName.isEmpty else { return nil }
        return CameraPanTilt.Target(server: server, stream: activeStreamName)
    }
}
