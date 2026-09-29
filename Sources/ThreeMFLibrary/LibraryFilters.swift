import Foundation

/// Everything the library knows about a file beyond its name, for searching and filtering.
public struct FileFacts: Sendable {
    /// Total print time of a sliced project.
    public var printTime: TimeInterval?
    public var details: ModelDetails?
    /// Whether every plate fits the printer; nil when unknown.
    public var fits: Bool?

    public init(printTime: TimeInterval? = nil, details: ModelDetails? = nil, fits: Bool? = nil) {
        self.printTime = printTime
        self.details = details
        self.fits = fits
    }
}

/// Filters of the model list. A filter that needs data the library has not read yet hides the file.
public struct LibraryFilters: Equatable, Sendable {
    public enum PrintTime: String, CaseIterable, Sendable {
        case any, upTo1h, upTo3h, upTo8h, over8h
    }

    public enum Slicing: String, CaseIterable, Sendable {
        case any, sliced, notSliced
    }

    public enum Colors: String, CaseIterable, Sendable {
        case any, single, multi
    }

    public enum Fit: String, CaseIterable, Sendable {
        case any, fits, tooBig
    }

    public enum Printed: String, CaseIterable, Sendable {
        case any, printed, notPrinted
    }

    public var printTime: PrintTime = .any
    public var slicing: Slicing = .any
    /// Upper-case filament type, e.g. "PETG"; nil = any.
    public var filamentType: String?
    public var colors: Colors = .any
    public var fit: Fit = .any
    public var printed: Printed = .any
    public var favoritesOnly = false

    public init() {}

    /// Number of filters that are switched on.
    public var activeCount: Int {
        [printTime != .any, slicing != .any, filamentType != nil, colors != .any,
         fit != .any, printed != .any, favoritesOnly].filter { $0 }.count
    }

    public var isActive: Bool { activeCount > 0 }

    public func matches(_ file: ModelFileItem, _ facts: FileFacts) -> Bool {
        if favoritesOnly, !file.isFavorite { return false }
        switch printed {
        case .any: break
        case .printed: if !file.isPrinted { return false }
        case .notPrinted: if file.isPrinted { return false }
        }
        switch slicing {
        case .any: break
        case .sliced: if facts.printTime == nil { return false }
        case .notSliced: if facts.printTime != nil { return false }
        }
        if printTime != .any {
            guard let time = facts.printTime else { return false }
            switch printTime {
            case .any: break
            case .upTo1h: if time > 3600 { return false }
            case .upTo3h: if time > 3 * 3600 { return false }
            case .upTo8h: if time > 8 * 3600 { return false }
            case .over8h: if time <= 8 * 3600 { return false }
            }
        }
        if let filamentType {
            guard let types = facts.details?.filamentTypes, types.contains(filamentType) else { return false }
        }
        if colors != .any {
            guard let count = facts.details?.colorCount, count > 0 else { return false }
            if colors == .single, count > 1 { return false }
            if colors == .multi, count < 2 { return false }
        }
        if fit != .any {
            guard let fits = facts.fits else { return false }
            if fit == .fits, !fits { return false }
            if fit == .tooBig, fits { return false }
        }
        return true
    }
}
