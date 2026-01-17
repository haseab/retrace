import Foundation
import SQLCipher
import Shared
import CoreGraphics

// MARK: - Node Queries

/// SQL queries for node table (Rewind-compatible)
/// Handles OCR text bounding boxes with textOffset/textLength references into searchRanking_content
enum NodeQueries {

    // MARK: - Batch Insert

    /// Insert multiple nodes for a frame
    /// Nodes must be pre-sorted in reading order (nodeOrder 0, 1, 2, ...)
    static func insertBatch(
        db: OpaquePointer,
        frameID: FrameID,
        nodes: [(textOffset: Int, textLength: Int, bounds: CGRect, windowIndex: Int?)],
        frameWidth: Int,
        frameHeight: Int
    ) throws {
        let sql = """
            INSERT INTO node (
                frameId, nodeOrder, textOffset, textLength,
                leftX, topY, width, height, windowIndex
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        for (index, node) in nodes.enumerated() {
            // Normalize coordinates to 0.0-1.0 range
            let normalized = Schema.normalizeRect(
                node.bounds,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )

            sqlite3_bind_int64(statement, 1, frameID.value)
            sqlite3_bind_int(statement, 2, Int32(index))  // nodeOrder
            sqlite3_bind_int(statement, 3, Int32(node.textOffset))
            sqlite3_bind_int(statement, 4, Int32(node.textLength))
            sqlite3_bind_double(statement, 5, normalized.leftX)
            sqlite3_bind_double(statement, 6, normalized.topY)
            sqlite3_bind_double(statement, 7, normalized.width)
            sqlite3_bind_double(statement, 8, normalized.height)

            if let windowIndex = node.windowIndex {
                sqlite3_bind_int(statement, 9, Int32(windowIndex))
            } else {
                sqlite3_bind_null(statement, 9)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.queryFailed(
                    query: sql,
                    underlying: String(cString: sqlite3_errmsg(db))
                )
            }

            sqlite3_reset(statement)
        }
    }

    // MARK: - Select

    /// Get all nodes for a frame, ordered by nodeOrder
    /// Returns nodes with denormalized coordinates
    static func getByFrameID(
        db: OpaquePointer,
        frameID: FrameID,
        frameWidth: Int,
        frameHeight: Int
    ) throws -> [OCRNode] {
        let sql = """
            SELECT
                id, nodeOrder, textOffset, textLength,
                leftX, topY, width, height, windowIndex
            FROM node
            WHERE frameId = ?
            ORDER BY nodeOrder ASC
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var results: [OCRNode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try parseNodeRow(
                statement: statement!,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            ))
        }
        return results
    }

    /// Get nodes with their text extracted from searchRanking_content
    static func getNodesWithText(
        db: OpaquePointer,
        frameID: FrameID,
        frameWidth: Int,
        frameHeight: Int
    ) throws -> [(node: OCRNode, text: String)] {
        let sql = """
            SELECT
                n.id,
                n.nodeOrder,
                n.textOffset,
                n.textLength,
                n.leftX,
                n.topY,
                n.width,
                n.height,
                n.windowIndex,
                sc.c0
            FROM node n
            JOIN doc_segment ds ON n.frameId = ds.frameId
            JOIN searchRanking_content sc ON ds.docid = sc.id
            WHERE n.frameId = ?
            ORDER BY n.nodeOrder ASC
            """

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameID.value)

        var results: [(OCRNode, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let node = try parseNodeRow(
                statement: statement!,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )

            // Extract text substring using textOffset and textLength
            guard let fullTextCStr = sqlite3_column_text(statement, 9) else {
                throw DatabaseError.queryFailed(
                    query: sql,
                    underlying: "Missing searchRanking_content.c0"
                )
            }
            let fullText = String(cString: fullTextCStr)

            let startIndex = fullText.index(
                fullText.startIndex,
                offsetBy: node.textOffset,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex

            let endIndex = fullText.index(
                startIndex,
                offsetBy: node.textLength,
                limitedBy: fullText.endIndex
            ) ?? fullText.endIndex

            let text = String(fullText[startIndex..<endIndex])
            results.append((node, text))
        }

        return results
    }

    // MARK: - Delete

    static func deleteByFrameID(db: OpaquePointer, frameID: FrameID) throws {
        let sql = "DELETE FROM node WHERE frameId = ?"

        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        sqlite3_bind_int64(statement, 1, frameID.value)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Helper

    private static func parseNodeRow(
        statement: OpaquePointer,
        frameWidth: Int,
        frameHeight: Int
    ) throws -> OCRNode {
        let id = sqlite3_column_int64(statement, 0)
        let nodeOrder = Int(sqlite3_column_int(statement, 1))
        let textOffset = Int(sqlite3_column_int(statement, 2))
        let textLength = Int(sqlite3_column_int(statement, 3))
        let leftX = sqlite3_column_double(statement, 4)
        let topY = sqlite3_column_double(statement, 5)
        let width = sqlite3_column_double(statement, 6)
        let height = sqlite3_column_double(statement, 7)
        let windowIndex = sqlite3_column_type(statement, 8) != SQLITE_NULL
            ? Int(sqlite3_column_int(statement, 8))
            : nil

        // Denormalize coordinates back to pixels
        let bounds = Schema.denormalizeRect(
            leftX: leftX,
            topY: topY,
            width: width,
            height: height,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )

        return OCRNode(
            id: id,
            nodeOrder: nodeOrder,
            textOffset: textOffset,
            textLength: textLength,
            bounds: bounds,
            windowIndex: windowIndex
        )
    }
}
