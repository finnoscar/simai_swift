// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Source-language fallbacks for the existing parser/settings error labels.
func airMaiLocalized(_ text: String) -> String { text }

extension SimaiChartParser {
    /// Parse a raw simai inote expression without constructing a maidata file.
    public static func parse(notation: String, bpm: Double = 120, offset: TimeInterval = 0) throws -> SimaiChart {
        guard bpm.isFinite, bpm > 0, offset.isFinite else { throw SimaiChartParseError.emptyChart }
        return try parse(maidata: "&bpm=\(bpm)\n&first=\(offset)\n&inote_2=\(notation)", levelIndex: 0)
    }
}
