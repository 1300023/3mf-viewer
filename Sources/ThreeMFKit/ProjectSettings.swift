import Foundation

/// Printer / profile values and filament colours of a slicer project:
/// `Metadata/project_settings.config` (Bambu Studio / OrcaSlicer, JSON) or `Metadata/Slic3r_PE.config` (PrusaSlicer, INI).
struct ProjectSettings {
    var printerName: String?
    var nozzleDiameter: String?
    var layerHeight: String?
    /// Filament types per slot ("PLA", "PETG", …).
    var filamentTypes: [String] = []
    /// Filament colours per slot (index 0 = extruder 1).
    var filamentColors: [RGBAColor] = []

    /// Reads the settings of whichever slicer wrote the file (empty for plain 3MF).
    static func load(from archive: ZipArchive) -> ProjectSettings {
        let prusa = (try? archive.contents(path: "Metadata/Slic3r_PE.config")).flatMap { $0 }
            .map(PrintProjectParser.parsePrusaProjectSettings)
        guard let data = try? archive.contents(path: "Metadata/project_settings.config") else {
            return prusa ?? ProjectSettings()
        }
        var settings = PrintProjectParser.parseBambuProjectSettings(data)
        // A project converted between slicers may keep its colours only in the PrusaSlicer config.
        if settings.filamentColors.isEmpty, let colors = prusa?.filamentColors {
            settings.filamentColors = colors
        }
        return settings
    }
}

extension PrintProjectParser {
    /// Bambu Studio / OrcaSlicer: JSON whose values are strings or arrays of strings (one per filament / extruder).
    static func parseBambuProjectSettings(_ data: Data) -> ProjectSettings {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ProjectSettings() }
        func first(_ key: String) -> String? {
            let value = (json[key] as? String) ?? (json[key] as? [String])?.first
            guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        var settings = ProjectSettings()
        settings.printerName = first("printer_model") ?? first("printer_settings_id")
        settings.nozzleDiameter = first("nozzle_diameter")
        settings.layerHeight = first("layer_height")
        settings.filamentTypes = (json["filament_type"] as? [String]) ?? []
        let colours = (json["filament_colour"] as? [String]) ?? (json["extruder_colour"] as? [String]) ?? []
        settings.filamentColors = colours.map { RGBAColor(hex: $0) ?? .unknownFilament }
        return settings
    }

    /// PrusaSlicer: INI-like lines such as `; printer_model = MK4` or `; filament_colour = #FF8000;#DB5182`.
    static func parsePrusaProjectSettings(_ data: Data) -> ProjectSettings {
        let values = parseINI(data)
        func nonEmpty(_ key: String) -> String? {
            guard let v = values[key]?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")), !v.isEmpty else { return nil }
            return v
        }
        /// "a;"b";c" → ["a", "b", "c"] (empty items are kept so that indices match extruders).
        func list(_ key: String) -> [String] {
            guard let value = values[key] else { return [] }
            return value.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")) }
        }

        var settings = ProjectSettings()
        settings.printerName = nonEmpty("printer_settings_id") ?? nonEmpty("printer_model")
        settings.nozzleDiameter = nonEmpty("nozzle_diameter")?
            .split(whereSeparator: { $0 == "," || $0 == ";" }).first.map(String.init)
        settings.layerHeight = nonEmpty("layer_height")
        settings.filamentTypes = list("filament_type").filter { !$0.isEmpty }

        // The extruder colour wins; an empty one falls back to the filament colour.
        let extruderColours = list("extruder_colour")
        let filamentColours = list("filament_colour")
        settings.filamentColors = (0 ..< max(extruderColours.count, filamentColours.count)).map { index in
            if index < extruderColours.count, let color = RGBAColor(hex: extruderColours[index]) { return color }
            if index < filamentColours.count, let color = RGBAColor(hex: filamentColours[index]) { return color }
            return .unknownFilament
        }
        return settings
    }

    /// `key = value` lines; a leading `;` (comment marker used by PrusaSlicer) is ignored.
    static func parseINI(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

extension RGBAColor {
    /// Used when a slicer lists a filament without a readable colour.
    static let unknownFilament = RGBAColor(r: 0.8, g: 0.8, b: 0.8)
}
