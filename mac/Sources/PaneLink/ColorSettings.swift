import Foundation

/// Per-monitor picture adjustments, applied live by the Windows viewer's shader.
struct ColorSettings: Codable, Equatable {
    var brightness: Double = 0      // -0.3 ... 0.3
    var contrast: Double = 1        // 0.5 ... 1.5
    var saturation: Double = 1      // 0 ... 2
    var gamma: Double = 1           // 0.6 ... 1.6   (>1 brightens midtones)
    var temperature: Double = 0     // -1 cool ... +1 warm

    enum Preset: String, CaseIterable, Identifiable {
        case standard = "Standard", vivid = "Vivid", warm = "Warm", cool = "Cool", night = "Night", custom = "Custom"
        var id: String { rawValue }
        var settings: ColorSettings? {
            switch self {
            case .standard: return ColorSettings()
            case .vivid: return ColorSettings(brightness: 0, contrast: 1.08, saturation: 1.25, gamma: 1, temperature: 0)
            case .warm: return ColorSettings(temperature: 0.4)
            case .cool: return ColorSettings(temperature: -0.35)
            case .night: return ColorSettings(brightness: -0.05, contrast: 0.95, saturation: 0.9, gamma: 1, temperature: 0.9)
            case .custom: return nil
            }
        }
    }

    var preset: Preset { Preset.allCases.first { $0.settings == self } ?? .custom }

    /// Simple white-balance tint: warm pulls blue (and a little green) down, cool pulls red down.
    var tint: (Float, Float, Float) {
        let t = Float(temperature)
        if t >= 0 { return (1, 1 - 0.10 * t, 1 - 0.32 * t) }
        return (1 + 0.28 * t, 1 + 0.06 * t, 1)
    }

    init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1, gamma: Double = 1, temperature: Double = 0) {
        self.brightness = brightness; self.contrast = contrast; self.saturation = saturation
        self.gamma = gamma; self.temperature = temperature
    }
}
