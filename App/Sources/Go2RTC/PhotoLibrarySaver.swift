import AVFoundation
import Foundation
import Photos

/// Saves a finished recording to the Photos library (add-only permission).
/// Expects a file already passed through `RecordingFinalizer` (regular MP4, Photos indexes it properly).
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                #if os(macOS)
                return String(localized: "No permission to add videos to Photos. Turn it on in System Settings → Privacy & Security → Photos.")
                #else
                return String(localized: "No permission to add videos to Photos. Turn it on in iOS Settings → Waiting Paws.")
                #endif
            case .failed(let why): return String(localized: "Couldn’t save to Photos: \(why)")
            }
        }
    }

    static func save(videoAt url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw SaveError.failed(String(localized: "the recording file is empty")) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            let codecs = await codecSummary(url)
            throw SaveError.failed(String(localized: "\(error.localizedDescription) (codecs: \(codecs))"))
        }
    }

    /// "avc1, mp4a" style list of track codecs, for error messages.
    private static func codecSummary(_ url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return String(localized: "couldn’t read the file") }
        var names: [String] = []
        for track in tracks {
            guard let descriptions = try? await track.load(.formatDescriptions) else { continue }
            for description in descriptions {
                let code = CMFormatDescriptionGetMediaSubType(description)
                let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
                names.append(String(chars))
            }
        }
        return names.isEmpty ? String(localized: "no tracks") : names.joined(separator: ", ")
    }
}
