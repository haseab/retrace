import App
import AppKit
import AVFoundation
import Database
import Foundation
import ImageIO
import Processing
import Shared
import SwiftUI

extension SimpleTimelineViewModel {
    public var ocrNodesInZoomRegion: [OCRNodeWithText] {
        guard let region = zoomRegion, isZoomRegionActive else {
            return ocrNodes
        }

        return ocrNodes.filter { node in
            let nodeRight = node.x + node.width
            let nodeBottom = node.y + node.height
            let regionRight = region.origin.x + region.width
            let regionBottom = region.origin.y + region.height

            return !(nodeRight < region.origin.x || node.x > regionRight ||
                     nodeBottom < region.origin.y || node.y > regionBottom)
        }
    }

    public func getVisibleCharacterRange(for node: OCRNodeWithText) -> (start: Int, end: Int)? {
        guard let region = zoomRegion, isZoomRegionActive else {
            return nil
        }

        let nodeRight = node.x + node.width
        let regionRight = region.origin.x + region.width
        let needsLeftClip = node.x < region.origin.x
        let needsRightClip = nodeRight > regionRight

        guard needsLeftClip || needsRightClip else {
            return nil
        }

        let textLength = node.text.count
        guard textLength > 0, node.width > 0 else { return nil }

        let clippedX = max(node.x, region.origin.x)
        let clippedRight = min(nodeRight, regionRight)

        let visibleStartFraction = (clippedX - node.x) / node.width
        let visibleEndFraction = (clippedRight - node.x) / node.width

        let visibleStartChar = OCRTextLayoutEstimator.characterIndex(
            in: node.text,
            atFraction: visibleStartFraction
        )
        let visibleEndChar = OCRTextLayoutEstimator.characterIndex(
            in: node.text,
            atFraction: visibleEndFraction
        )

        return (start: max(0, visibleStartChar), end: min(textLength, visibleEndChar))
    }

    private func findCharacterPositionInZoomRegion(at point: CGPoint) -> (nodeID: Int, charIndex: Int)? {
        let nodesInRegion = ocrNodesInZoomRegion
        let yTolerance: CGFloat = 0.02
        let hitPadding: CGFloat = 0.01

        let sortedNodes = nodesInRegion.sorted { node1, node2 in
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        for node in sortedNodes {
            if point.x >= node.x && point.x <= node.x + node.width &&
               point.y >= node.y && point.y <= node.y + node.height {
                let relativeX = (point.x - node.x) / node.width
                let clampedIndex = OCRTextLayoutEstimator.characterIndex(
                    in: node.text,
                    atFraction: relativeX
                )
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        for node in sortedNodes {
            let paddedMinX = node.x - hitPadding
            let paddedMaxX = node.x + node.width + hitPadding
            let paddedMinY = node.y - hitPadding
            let paddedMaxY = node.y + node.height + hitPadding

            if point.x >= paddedMinX && point.x <= paddedMaxX &&
               point.y >= paddedMinY && point.y <= paddedMaxY {
                let clampedX = max(node.x, min(node.x + node.width, point.x))
                let relativeX = (clampedX - node.x) / node.width
                let clampedIndex = OCRTextLayoutEstimator.characterIndex(
                    in: node.text,
                    atFraction: relativeX
                )
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        var rows: [[OCRNodeWithText]] = []
        var currentRow: [OCRNodeWithText] = []
        var currentRowY: CGFloat?

        for node in sortedNodes {
            if let rowY = currentRowY, abs(node.y - rowY) <= yTolerance {
                currentRow.append(node)
            } else {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = [node]
                currentRowY = node.y
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        guard !rows.isEmpty else { return nil }

        var bestRowIndex = 0
        var bestRowDistance: CGFloat = .infinity

        for (index, row) in rows.enumerated() {
            guard let firstNode = row.first else { continue }
            let rowMinY = row.map { $0.y }.min() ?? firstNode.y
            let rowMaxY = row.map { $0.y + $0.height }.max() ?? (firstNode.y + firstNode.height)
            let rowCenterY = (rowMinY + rowMaxY) / 2

            let distance = abs(point.y - rowCenterY)
            if distance < bestRowDistance {
                bestRowDistance = distance
                bestRowIndex = index
            }
        }

        let targetRow = rows[bestRowIndex]
        let rowMinX = targetRow.map { $0.x }.min() ?? 0
        let rowMaxX = targetRow.map { $0.x + $0.width }.max() ?? 1

        if point.x <= rowMinX {
            if let firstNode = targetRow.first {
                return (nodeID: firstNode.id, charIndex: 0)
            }
        } else if point.x >= rowMaxX {
            if let lastNode = targetRow.last {
                return (nodeID: lastNode.id, charIndex: lastNode.text.count)
            }
        } else {
            var bestNode: OCRNodeWithText?
            var bestCharIndex = 0
            var bestDistance: CGFloat = .infinity

            for node in targetRow {
                let nodeStart = node.x
                let nodeEnd = node.x + node.width

                let distToStart = abs(point.x - nodeStart)
                if distToStart < bestDistance {
                    bestDistance = distToStart
                    bestNode = node
                    bestCharIndex = 0
                }

                let distToEnd = abs(point.x - nodeEnd)
                if distToEnd < bestDistance {
                    bestDistance = distToEnd
                    bestNode = node
                    bestCharIndex = node.text.count
                }

                if point.x >= nodeStart && point.x <= nodeEnd {
                    let relativeX = (point.x - node.x) / node.width
                    return (
                        nodeID: node.id,
                        charIndex: OCRTextLayoutEstimator.characterIndex(
                            in: node.text,
                            atFraction: relativeX
                        )
                    )
                }
            }

            if let node = bestNode {
                return (nodeID: node.id, charIndex: bestCharIndex)
            }
        }

        if let firstNode = sortedNodes.first {
            return (nodeID: firstNode.id, charIndex: 0)
        }

        return nil
    }

    func findCharacterPosition(at point: CGPoint) -> (nodeID: Int, charIndex: Int)? {
        let yTolerance: CGFloat = 0.02
        let hitPadding: CGFloat = 0.01

        let sortedNodes = ocrNodes.sorted { node1, node2 in
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        for node in sortedNodes {
            if point.x >= node.x && point.x <= node.x + node.width &&
               point.y >= node.y && point.y <= node.y + node.height {
                let relativeX = (point.x - node.x) / node.width
                let clampedIndex = OCRTextLayoutEstimator.characterIndex(
                    in: node.text,
                    atFraction: relativeX
                )
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        for node in sortedNodes {
            let paddedMinX = node.x - hitPadding
            let paddedMaxX = node.x + node.width + hitPadding
            let paddedMinY = node.y - hitPadding
            let paddedMaxY = node.y + node.height + hitPadding

            if point.x >= paddedMinX && point.x <= paddedMaxX &&
               point.y >= paddedMinY && point.y <= paddedMaxY {
                let clampedX = max(node.x, min(node.x + node.width, point.x))
                let relativeX = (clampedX - node.x) / node.width
                let clampedIndex = OCRTextLayoutEstimator.characterIndex(
                    in: node.text,
                    atFraction: relativeX
                )
                return (nodeID: node.id, charIndex: clampedIndex)
            }
        }

        var rows: [[OCRNodeWithText]] = []
        var currentRow: [OCRNodeWithText] = []
        var currentRowY: CGFloat?

        for node in sortedNodes {
            if let rowY = currentRowY, abs(node.y - rowY) <= yTolerance {
                currentRow.append(node)
            } else {
                if !currentRow.isEmpty {
                    rows.append(currentRow)
                }
                currentRow = [node]
                currentRowY = node.y
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        guard !rows.isEmpty else { return nil }

        var bestRowIndex = 0
        var bestRowDistance: CGFloat = .infinity

        for (index, row) in rows.enumerated() {
            guard let firstNode = row.first else { continue }
            let rowMinY = row.map { $0.y }.min() ?? firstNode.y
            let rowMaxY = row.map { $0.y + $0.height }.max() ?? (firstNode.y + firstNode.height)
            let rowCenterY = (rowMinY + rowMaxY) / 2

            let distance = abs(point.y - rowCenterY)
            if distance < bestRowDistance {
                bestRowDistance = distance
                bestRowIndex = index
            }
        }

        let targetRow = rows[bestRowIndex]
        let rowMinX = targetRow.map { $0.x }.min() ?? 0
        let rowMaxX = targetRow.map { $0.x + $0.width }.max() ?? 1

        if point.x <= rowMinX {
            if let firstNode = targetRow.first {
                return (nodeID: firstNode.id, charIndex: 0)
            }
        } else if point.x >= rowMaxX {
            if let lastNode = targetRow.last {
                return (nodeID: lastNode.id, charIndex: lastNode.text.count)
            }
        } else {
            var bestNode: OCRNodeWithText?
            var bestCharIndex = 0
            var bestDistance: CGFloat = .infinity

            for node in targetRow {
                let nodeStart = node.x
                let nodeEnd = node.x + node.width

                let distToStart = abs(point.x - nodeStart)
                if distToStart < bestDistance {
                    bestDistance = distToStart
                    bestNode = node
                    bestCharIndex = 0
                }

                let distToEnd = abs(point.x - nodeEnd)
                if distToEnd < bestDistance {
                    bestDistance = distToEnd
                    bestNode = node
                    bestCharIndex = node.text.count
                }

                if point.x >= nodeStart && point.x <= nodeEnd {
                    let relativeX = (point.x - node.x) / node.width
                    return (
                        nodeID: node.id,
                        charIndex: OCRTextLayoutEstimator.characterIndex(
                            in: node.text,
                            atFraction: relativeX
                        )
                    )
                }
            }

            if let node = bestNode {
                return (nodeID: node.id, charIndex: bestCharIndex)
            }
        }

        if let firstNode = sortedNodes.first {
            return (nodeID: firstNode.id, charIndex: 0)
        }

        return nil
    }

    public func getSelectionRange(for nodeID: Int) -> (start: Int, end: Int)? {
        if !boxSelectedNodeIDs.isEmpty {
            guard boxSelectedNodeIDs.contains(nodeID),
                  let node = ocrNodes.first(where: { $0.id == nodeID }) else {
                return nil
            }

            var rangeStart = 0
            var rangeEnd = node.text.count

            if let visibleRange = getVisibleCharacterRange(for: node) {
                rangeStart = max(rangeStart, visibleRange.start)
                rangeEnd = min(rangeEnd, visibleRange.end)
                if rangeEnd <= rangeStart {
                    return nil
                }
            }

            return (start: rangeStart, end: rangeEnd)
        }

        guard let start = selectionStart, let end = selectionEnd else { return nil }
        guard let dragStart = dragStartPoint, let dragEnd = dragEndPoint else {
            return getSelectionRangeFullScreen(for: nodeID)
        }

        let rectMinX = min(dragStart.x, dragEnd.x)
        let rectMaxX = max(dragStart.x, dragEnd.x)

        let nodesInRect = ocrNodes.filter { node in
            let nodeMinX = node.x
            let nodeMaxX = node.x + node.width
            return nodeMaxX > rectMinX && nodeMinX < rectMaxX
        }

        let sortedNodes = nodesInRect.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        guard let startNodeIndex = sortedNodes.firstIndex(where: { $0.id == start.nodeID }),
              let endNodeIndex = sortedNodes.firstIndex(where: { $0.id == end.nodeID }),
              let thisNodeIndex = sortedNodes.firstIndex(where: { $0.id == nodeID }) else {
            return nil
        }

        let (normalizedStartNodeIndex, normalizedEndNodeIndex, normalizedStartChar, normalizedEndChar): (Int, Int, Int, Int)
        if startNodeIndex <= endNodeIndex {
            normalizedStartNodeIndex = startNodeIndex
            normalizedEndNodeIndex = endNodeIndex
            normalizedStartChar = start.charIndex
            normalizedEndChar = end.charIndex
        } else {
            normalizedStartNodeIndex = endNodeIndex
            normalizedEndNodeIndex = startNodeIndex
            normalizedStartChar = end.charIndex
            normalizedEndChar = start.charIndex
        }

        guard thisNodeIndex >= normalizedStartNodeIndex && thisNodeIndex <= normalizedEndNodeIndex else {
            return nil
        }

        let node = sortedNodes[thisNodeIndex]
        let textLength = node.text.count

        var rangeStart: Int
        var rangeEnd: Int

        if thisNodeIndex == normalizedStartNodeIndex && thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = min(normalizedStartChar, normalizedEndChar)
            rangeEnd = max(normalizedStartChar, normalizedEndChar)
        } else if thisNodeIndex == normalizedStartNodeIndex {
            rangeStart = normalizedStartChar
            rangeEnd = textLength
        } else if thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = 0
            rangeEnd = normalizedEndChar
        } else {
            rangeStart = 0
            rangeEnd = textLength
        }

        if let visibleRange = getVisibleCharacterRange(for: node) {
            rangeStart = max(rangeStart, visibleRange.start)
            rangeEnd = min(rangeEnd, visibleRange.end)
            if rangeEnd <= rangeStart {
                return nil
            }
        }

        return (start: rangeStart, end: rangeEnd)
    }

    private func getCachedSortedNodesAndIndexMap() -> (sortedNodes: [OCRNodeWithText], indexMap: [Int: Int]) {
        if cachedNodesVersion == currentNodesVersion,
           let sortedNodes = cachedSortedNodes,
           let indexMap = cachedNodeIndexMap {
            return (sortedNodes, indexMap)
        }

        let sortedNodes = ocrNodes.sorted { node1, node2 in
            let yTolerance: CGFloat = 0.02
            if abs(node1.y - node2.y) > yTolerance {
                return node1.y < node2.y
            }
            return node1.x < node2.x
        }

        var indexMap: [Int: Int] = [:]
        indexMap.reserveCapacity(sortedNodes.count)
        for (index, node) in sortedNodes.enumerated() {
            indexMap[node.id] = index
        }

        cachedSortedNodes = sortedNodes
        cachedNodeIndexMap = indexMap
        cachedNodesVersion = currentNodesVersion

        return (sortedNodes, indexMap)
    }

    private func getSelectionRangeFullScreen(for nodeID: Int) -> (start: Int, end: Int)? {
        guard let start = selectionStart, let end = selectionEnd else { return nil }

        let (sortedNodes, indexMap) = getCachedSortedNodesAndIndexMap()

        guard let startNodeIndex = indexMap[start.nodeID],
              let endNodeIndex = indexMap[end.nodeID],
              let thisNodeIndex = indexMap[nodeID] else {
            return nil
        }

        let (normalizedStartNodeIndex, normalizedEndNodeIndex, normalizedStartChar, normalizedEndChar): (Int, Int, Int, Int)
        if startNodeIndex <= endNodeIndex {
            normalizedStartNodeIndex = startNodeIndex
            normalizedEndNodeIndex = endNodeIndex
            normalizedStartChar = start.charIndex
            normalizedEndChar = end.charIndex
        } else {
            normalizedStartNodeIndex = endNodeIndex
            normalizedEndNodeIndex = startNodeIndex
            normalizedStartChar = end.charIndex
            normalizedEndChar = start.charIndex
        }

        guard thisNodeIndex >= normalizedStartNodeIndex && thisNodeIndex <= normalizedEndNodeIndex else {
            return nil
        }

        let node = sortedNodes[thisNodeIndex]
        let textLength = node.text.count

        var rangeStart: Int
        var rangeEnd: Int

        if thisNodeIndex == normalizedStartNodeIndex && thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = min(normalizedStartChar, normalizedEndChar)
            rangeEnd = max(normalizedStartChar, normalizedEndChar)
        } else if thisNodeIndex == normalizedStartNodeIndex {
            rangeStart = normalizedStartChar
            rangeEnd = textLength
        } else if thisNodeIndex == normalizedEndNodeIndex {
            rangeStart = 0
            rangeEnd = normalizedEndChar
        } else {
            rangeStart = 0
            rangeEnd = textLength
        }

        if let visibleRange = getVisibleCharacterRange(for: node) {
            rangeStart = max(rangeStart, visibleRange.start)
            rangeEnd = min(rangeEnd, visibleRange.end)
            if rangeEnd <= rangeStart {
                return nil
            }
        }

        return (start: rangeStart, end: rangeEnd)
    }
}
