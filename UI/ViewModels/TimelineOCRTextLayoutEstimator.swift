import Foundation
import SwiftUI

enum OCRTextLayoutEstimator {
    private static let narrowCharacters = Set("ilIjtf|!,:;.`'".map(\.self))
    private static let mediumNarrowCharacters = Set("[](){}\\/".map(\.self))
    private static let wideCharacters = Set("MW@%&QGODmwo".map(\.self))
    private static let mediumWideCharacters = Set("ABHNUVXY02345689#".map(\.self))

    static func spanFractions(
        in text: String,
        range: Range<String.Index>
    ) -> (start: CGFloat, end: CGFloat) {
        let lowerBound = text.distance(from: text.startIndex, to: range.lowerBound)
        let upperBound = text.distance(from: text.startIndex, to: range.upperBound)
        return spanFractions(in: text, start: lowerBound, end: upperBound)
    }

    static func spanFractions(
        in text: String,
        start: Int,
        end: Int
    ) -> (start: CGFloat, end: CGFloat) {
        let characters = Array(text)
        guard !characters.isEmpty else { return (start: 0, end: 1) }

        let clampedStart = min(max(start, 0), max(characters.count - 1, 0))
        let clampedEnd = min(max(end, clampedStart + 1), characters.count)
        let cumulativeWidths = cumulativeCharacterWidths(for: characters)
        let totalWidth = max(cumulativeWidths.last ?? 0, 1)
        let startWidth = cumulativeWidths[clampedStart]
        let endWidth = cumulativeWidths[clampedEnd]
        let minimumSpanWidth = max(characterWidth(for: characters[clampedStart]) * 0.75, 0.01)
        let clampedEndWidth = min(max(endWidth, startWidth + minimumSpanWidth), totalWidth)

        return (
            start: startWidth / totalWidth,
            end: clampedEndWidth / totalWidth
        )
    }

    static func characterIndex(
        in text: String,
        atFraction fraction: CGFloat
    ) -> Int {
        let characters = Array(text)
        guard !characters.isEmpty else { return 0 }

        let clampedFraction = min(max(fraction, 0), 1)
        guard clampedFraction > 0 else { return 0 }
        guard clampedFraction < 1 else { return characters.count }

        let cumulativeWidths = cumulativeCharacterWidths(for: characters)
        let totalWidth = max(cumulativeWidths.last ?? 0, 1)
        let targetWidth = clampedFraction * totalWidth

        for index in 1..<cumulativeWidths.count where targetWidth < cumulativeWidths[index] {
            return index - 1
        }

        return characters.count
    }

    private static func cumulativeCharacterWidths(for characters: [Character]) -> [CGFloat] {
        var widths: [CGFloat] = [0]
        widths.reserveCapacity(characters.count + 1)

        var runningTotal: CGFloat = 0
        for character in characters {
            runningTotal += characterWidth(for: character)
            widths.append(runningTotal)
        }

        return widths
    }

    private static func characterWidth(for character: Character) -> CGFloat {
        if character.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
            return 0.35
        }

        guard character.unicodeScalars.allSatisfy(\.isASCII) else {
            return 1.1
        }

        if narrowCharacters.contains(character) {
            return 0.55
        }
        if mediumNarrowCharacters.contains(character) {
            return 0.75
        }
        if wideCharacters.contains(character) {
            return 1.35
        }
        if mediumWideCharacters.contains(character) {
            return 1.15
        }

        return 1.0
    }
}
