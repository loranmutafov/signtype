import Combine
import Foundation

enum Mode: String, CaseIterable, Identifiable {
    /// Each letter is typed the moment it stabilises.
    case live
    /// Letters accumulate; everything is typed when you stop.
    case batch
    /// Frames are sent to Gemma 4 when you stop; its transcript is typed.
    case gemma
    /// Live on-device letters and taught words; untaught motion signs go to Gemma 4.
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "Live (on-device)"
        case .batch: return "Batch, type at the end (on-device)"
        case .gemma: return "Batch via Gemma 4 (cloud)"
        case .hybrid: return "Hybrid: on-device, Gemma 4 for unknown signs"
        }
    }

    var usesGemma: Bool { self == .gemma || self == .hybrid }
    var typesLive: Bool { self == .live || self == .hybrid }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode") } }
    @Published var gemmaApiKey: String { didSet { d.set(gemmaApiKey, forKey: "gemmaApiKey") } }
    @Published var gemmaModel: String { didSet { d.set(gemmaModel, forKey: "gemmaModel") } }
    /// Stop automatically after this many seconds without a hand in view.
    @Published var autoStopSeconds: Double { didSet { d.set(autoStopSeconds, forKey: "autoStopSeconds") } }
    /// How many consecutive frames (≈15 fps) a letter must hold before it is accepted.
    @Published var stableFrames: Int { didSet { d.set(stableFrames, forKey: "stableFrames") } }

    static let defaultGemmaModel = "gemma-4-26b-a4b-it"

    private init() {
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .live
        gemmaApiKey = d.string(forKey: "gemmaApiKey") ?? ""
        gemmaModel = d.string(forKey: "gemmaModel") ?? Settings.defaultGemmaModel
        let auto = d.double(forKey: "autoStopSeconds")
        autoStopSeconds = auto > 0 ? auto : 4
        let stable = d.integer(forKey: "stableFrames")
        stableFrames = stable > 0 ? stable : 6
    }
}
