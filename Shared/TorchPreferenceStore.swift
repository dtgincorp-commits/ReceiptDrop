import Foundation

/// Quick-jump presets shown above the brightness slider — a fast, reliable
/// one-tap target for the common cases, without limiting the user to only
/// those three values.
enum TorchLevel: String, CaseIterable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// `AVCaptureDevice.setTorchModeOn(level:)` wants a value in (0, 1.0].
    var torchLevelValue: Float {
        switch self {
        case .low: return 0.3
        case .medium: return 0.65
        case .high: return 1.0
        }
    }
}

/// Remembers the torch on/off state between uses, so "off, for quiet social
/// dinners" sticks instead of the capture screen always igniting the torch.
/// Brightness deliberately is NOT remembered — every time the capture screen
/// opens, the torch starts at its dimmest so it never surprises someone with
/// a full-brightness blast; the user raises it from there if they need more
/// light. Plain `UserDefaults.standard` — a main-app-only preference, no App
/// Group needed.
enum TorchPreferenceStore {
    private static let isOnKey = "billCaptureTorchOn"
    private static let autoCaptureKey = "billCaptureAutoCapture"

    /// The brightness the torch always starts at when the capture screen
    /// opens — the slider's minimum, raised by the user from there.
    static let defaultBrightness: Float = 0.05

    /// Defaults to on — matches the feature's original "dark restaurant"
    /// motivation — but immediately becomes whatever the user last chose.
    static var isOn: Bool {
        get {
            if UserDefaults.standard.object(forKey: isOnKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: isOnKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: isOnKey) }
    }

    /// Whether the capture screen auto-fires the shutter once the bill holds
    /// steady in frame, or waits for a manual shutter tap. Defaults to on —
    /// it's the more forgiving option for a senior user's less-steady
    /// hands — but stays off once someone turns it off (e.g. it kept
    /// mis-firing on a cluttered table).
    static var autoCaptureEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoCaptureKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoCaptureKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCaptureKey) }
    }
}
