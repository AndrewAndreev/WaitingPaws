import Foundation
import Observation
import WaitingPawsCore

/// Turning a pan/tilt camera from the live view.
///
/// Mi Home turns the camera when a finger slides over the picture, so a pinch or a stray touch moves it. Here nothing on
/// the picture turns the camera: pinch and drag only zoom the picture. Turning is a mode the user switches on (the
/// toolbar on the Mac, the button in the picture's corner on the iPhone). It shows a pad with four arrows (and on the
/// Mac takes the arrow keys) and switches itself off after `idleTimeout` without presses. A press is one step of the
/// motor, about a tenth of the frame; holding repeats the step.
@MainActor
@Observable
final class CameraPanTilt {
    /// Where the steps go: the go2rtc that serves the picture (the linked Mac's for a linked iPhone) and the stream.
    struct Target: Equatable {
        var server: Go2RTCServer
        var stream: String
    }

    private(set) var isActive = false
    /// The direction held right now (a pad arrow or an arrow key).
    private(set) var held: PanTiltDirection?
    /// Why the last step failed, shown under the pad until the next one goes through.
    private(set) var failure: String?
    /// When the mode switches itself off; every press moves it on.
    private(set) var idleDeadline: Date?

    static let idleTimeout: TimeInterval = 10
    /// Between steps while held. The motor needs ~0.4 s for a step; faster commands only pile up in the camera.
    static let repeatInterval: Duration = .milliseconds(450)
    /// A hold stops by itself after this many steps (a lost mouse-up or key-up must not spin the camera round).
    static let maxHeldSteps = 30

    @ObservationIgnored private var client: Go2RTCClient?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var idleTask: Task<Void, Never>?

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        failure = nil
        touch()
    }

    func stop() {
        isActive = false
        held = nil
        failure = nil
        holdTask?.cancel()
        holdTask = nil
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
    }

    /// Arrow down: a step now and another every `repeatInterval` until `release()`.
    func press(_ direction: PanTiltDirection, target: Target?) {
        guard isActive, held != direction else { return }
        held = direction
        touch()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            var steps = 0
            while let self, !Task.isCancelled, self.held == direction, steps < Self.maxHeldSteps {
                guard await self.step(direction, target: target) else { break }
                steps += 1
                try? await Task.sleep(for: Self.repeatInterval)
            }
            if self?.held == direction { self?.held = nil }
        }
    }

    /// Arrow up. A quick tap has sent its one step already. Letting go of another arrow than the held one (two keys
    /// at once) changes nothing.
    func release(_ direction: PanTiltDirection) {
        guard held == direction || held == nil else { return }
        held = nil
        if isActive { touch() }
    }

    private func step(_ direction: PanTiltDirection, target: Target?) async -> Bool {
        touch()
        #if DEBUG
        // `--demo-camera-modes`: a C302 without a camera behind it; steps only light the arrows.
        if target == nil, CommandLine.arguments.contains("--demo-camera-modes") {
            try? await Task.sleep(for: .milliseconds(120))
            return true
        }
        #endif
        guard let target else {
            failure = String(localized: "The camera is offline")
            return false
        }
        if client?.server != target.server { client = Go2RTCClient(server: target.server) }
        do {
            try await client?.turnCamera(stream: target.stream, direction)
            failure = nil
            return true
        } catch {
            print("[camera] turn \(direction): \(error.localizedDescription)")
            failure = Self.message(error)
            return false
        }
    }

    /// Restarts the countdown to switching off; a held arrow keeps the mode on.
    private func touch() {
        idleDeadline = Date().addingTimeInterval(Self.idleTimeout)
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard let self, !Task.isCancelled, self.isActive else { return }
            if self.held == nil { self.stop() } else { self.touch() }
        }
    }

    private static func message(_ error: Error) -> String {
        switch error as? Go2RTCError {
        case .http(404, _):
            // An external go2rtc, or the linked computer runs a Waiting Paws from before turning.
            return String(localized: "This go2rtc can’t turn the camera — update Waiting Paws on the computer with the camera")
        case .http(409, _):
            return String(localized: "The camera isn’t sending video right now — wait for the picture")
        case .http(502, _):
            return String(localized: "The camera didn’t take the command")
        default:
            return error.localizedDescription
        }
    }
}
