import CoreGraphics
import Foundation
import SQLCipher
import Shared

/// Reads and writes accessibility tree snapshots (tables added in V21).
///
/// Nodes are content-addressed: a node's hash covers its attributes and its children's
/// hashes, so a subtree that did not change between frames is stored once and reused.
enum AXSnapshotQueries {

    struct StoredSnapshotInfo: Equatable {
        let rootNodeId: Int64
        let newNodeCount: Int
    }

    /// Store `snapshot` for `frameId`, replacing any earlier snapshot for that frame.
    @discardableResult
    static func replace(db: OpaquePointer, frameId: Int64, snapshot: AXTreeSnapshot) throws -> StoredSnapshotInfo {
        let hashed = HashedNode(snapshot.root)

        try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            var statements = Statements(db: db)
            defer { statements.finalize() }

            var newNodeCount = 0
            let rootId = try store(hashed, statements: &statements, newNodeCount: &newNodeCount)

            let sql = """
                INSERT OR REPLACE INTO frame_ax_snapshot
                    (frameId, rootNodeId, bundleID, processID, nodeCount, isTruncated, walkMs)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(db: db, sql: sql, statement: &statement)
            sqlite3_bind_int64(statement, 1, frameId)
            sqlite3_bind_int64(statement, 2, rootId)
            bind(statement, 3, snapshot.bundleID)
            sqlite3_bind_int64(statement, 4, Int64(snapshot.processID))
            sqlite3_bind_int64(statement, 5, Int64(snapshot.nodeCount))
            sqlite3_bind_int64(statement, 6, snapshot.isTruncated ? 1 : 0)
            sqlite3_bind_int64(statement, 7, Int64(snapshot.walkMilliseconds))
            try step(db: db, sql: sql, statement: statement)

            try exec(db: db, sql: "COMMIT;")
            return StoredSnapshotInfo(rootNodeId: rootId, newNodeCount: newNodeCount)
        } catch {
            try? exec(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    /// The snapshot stored for `frameId`, or nil.
    static func fetch(db: OpaquePointer, frameId: Int64) throws -> AXTreeSnapshot? {
        let headerSQL = """
            SELECT rootNodeId, bundleID, processID, nodeCount, isTruncated, walkMs
            FROM frame_ax_snapshot WHERE frameId = ?;
            """
        var header: OpaquePointer?
        defer { sqlite3_finalize(header) }
        try prepare(db: db, sql: headerSQL, statement: &header)
        sqlite3_bind_int64(header, 1, frameId)
        guard sqlite3_step(header) == SQLITE_ROW else { return nil }

        let rootId = sqlite3_column_int64(header, 0)
        let bundleID = text(header!, 1)
        let processID = Int32(truncatingIfNeeded: sqlite3_column_int64(header, 2))
        let nodeCount = Int(sqlite3_column_int64(header, 3))
        let isTruncated = sqlite3_column_int64(header, 4) != 0
        let walkMs = Int(sqlite3_column_int64(header, 5))

        // Load every reachable node and edge in two queries, then assemble.
        let reachable = """
            WITH RECURSIVE tree(id) AS (
                SELECT ?
                UNION
                SELECT c.childId FROM ax_node_child c JOIN tree ON c.parentId = tree.id
            )
            """
        var nodes: [Int64: (role: String, subrole: String?, title: String?, value: String?, label: String?, bounds: CGRect?)] = [:]
        do {
            let sql = reachable + """
                SELECT n.id, n.role, n.subrole, n.title, n.value, n.label, n.x, n.y, n.width, n.height
                FROM ax_node n JOIN tree ON n.id = tree.id;
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(db: db, sql: sql, statement: &statement)
            sqlite3_bind_int64(statement, 1, rootId)
            while sqlite3_step(statement) == SQLITE_ROW {
                let bounds: CGRect? = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : CGRect(
                    x: sqlite3_column_double(statement, 6),
                    y: sqlite3_column_double(statement, 7),
                    width: sqlite3_column_double(statement, 8),
                    height: sqlite3_column_double(statement, 9)
                )
                nodes[sqlite3_column_int64(statement, 0)] = (
                    text(statement!, 1) ?? "",
                    text(statement!, 2),
                    text(statement!, 3),
                    text(statement!, 4),
                    text(statement!, 5),
                    bounds
                )
            }
        }

        var children: [Int64: [Int64]] = [:]
        do {
            let sql = reachable + """
                SELECT c.parentId, c.childId
                FROM ax_node_child c JOIN tree ON c.parentId = tree.id
                ORDER BY c.parentId, c.position;
                """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(db: db, sql: sql, statement: &statement)
            sqlite3_bind_int64(statement, 1, rootId)
            while sqlite3_step(statement) == SQLITE_ROW {
                children[sqlite3_column_int64(statement, 0), default: []].append(sqlite3_column_int64(statement, 1))
            }
        }

        func build(_ id: Int64, depth: Int) -> AXNodeSnapshot? {
            guard depth < 512, let node = nodes[id] else { return nil }
            return AXNodeSnapshot(
                role: node.role,
                subrole: node.subrole,
                title: node.title,
                value: node.value,
                label: node.label,
                bounds: node.bounds,
                children: (children[id] ?? []).compactMap { build($0, depth: depth + 1) }
            )
        }

        guard let root = build(rootId, depth: 0) else { return nil }
        return AXTreeSnapshot(
            bundleID: bundleID,
            processID: processID,
            root: root,
            nodeCount: nodeCount,
            isTruncated: isTruncated,
            walkMilliseconds: walkMs
        )
    }

    /// Delete the snapshot rows of `frameIds` (for example frames being redacted). Their
    /// nodes stay until `purgeUnreferencedNodes` runs.
    static func deleteSnapshots(db: OpaquePointer, frameIds: [Int64]) throws {
        guard !frameIds.isEmpty else { return }
        let placeholders = frameIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "DELETE FROM frame_ax_snapshot WHERE frameId IN (\(placeholders));"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(db: db, sql: sql, statement: &statement)
        for (index, frameId) in frameIds.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), frameId)
        }
        try step(db: db, sql: sql, statement: statement)
    }

    /// Delete nodes that no remaining frame snapshot reaches. Run after frames are
    /// deleted (snapshot rows go with their frame; shared nodes are kept until here).
    /// Returns the number of nodes deleted.
    @discardableResult
    static func purgeUnreferencedNodes(db: OpaquePointer) throws -> Int {
        try exec(db: db, sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try exec(db: db, sql: """
                CREATE TEMP TABLE IF NOT EXISTS ax_live_node (id INTEGER PRIMARY KEY);
                DELETE FROM temp.ax_live_node;
                WITH RECURSIVE live(id) AS (
                    SELECT rootNodeId FROM frame_ax_snapshot
                    UNION
                    SELECT c.childId FROM ax_node_child c JOIN live ON c.parentId = live.id
                )
                INSERT INTO temp.ax_live_node (id) SELECT id FROM live;
                DELETE FROM ax_node WHERE id NOT IN (SELECT id FROM temp.ax_live_node);
                """)
            let deleted = Int(sqlite3_changes(db))
            try exec(db: db, sql: """
                DELETE FROM ax_node_child WHERE parentId NOT IN (SELECT id FROM temp.ax_live_node);
                DELETE FROM temp.ax_live_node;
                """)
            try exec(db: db, sql: "COMMIT;")
            return deleted
        } catch {
            try? exec(db: db, sql: "ROLLBACK;")
            throw error
        }
    }

    // MARK: - Storing

    /// A node with its subtree hash computed once, bottom-up.
    private struct HashedNode {
        let node: AXNodeSnapshot
        let hash: Data
        let children: [HashedNode]

        init(_ node: AXNodeSnapshot) {
            let children = node.children.map(HashedNode.init)
            self.node = node
            self.children = children
            self.hash = node.contentHash(childHashes: children.map(\.hash))
        }
    }

    private struct Statements {
        let db: OpaquePointer
        var lookup: OpaquePointer?
        var insertNode: OpaquePointer?
        var insertChild: OpaquePointer?

        init(db: OpaquePointer) {
            self.db = db
        }

        mutating func finalize() {
            sqlite3_finalize(lookup)
            sqlite3_finalize(insertNode)
            sqlite3_finalize(insertChild)
        }
    }

    /// Store `hashed` top-down: when a subtree's hash already exists, reuse it without
    /// visiting its children, so unchanged parts of the UI cost one lookup.
    private static func store(_ hashed: HashedNode, statements: inout Statements, newNodeCount: inout Int) throws -> Int64 {
        let db = statements.db

        if statements.lookup == nil {
            try prepare(db: db, sql: "SELECT id FROM ax_node WHERE hash = ?;", statement: &statements.lookup)
        }
        sqlite3_reset(statements.lookup)
        _ = hashed.hash.withUnsafeBytes {
            sqlite3_bind_blob(statements.lookup, 1, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        if sqlite3_step(statements.lookup) == SQLITE_ROW {
            return sqlite3_column_int64(statements.lookup, 0)
        }

        let childIds = try hashed.children.map { try store($0, statements: &statements, newNodeCount: &newNodeCount) }

        let insertNodeSQL = """
            INSERT INTO ax_node (hash, role, subrole, title, value, label, x, y, width, height)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        if statements.insertNode == nil {
            try prepare(db: db, sql: insertNodeSQL, statement: &statements.insertNode)
        }
        let insert = statements.insertNode
        sqlite3_reset(insert)
        sqlite3_clear_bindings(insert)
        _ = hashed.hash.withUnsafeBytes {
            sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        let node = hashed.node
        bind(insert, 2, node.role)
        bind(insert, 3, node.subrole)
        bind(insert, 4, node.title)
        bind(insert, 5, node.value)
        bind(insert, 6, node.label)
        if let bounds = node.bounds {
            sqlite3_bind_double(insert, 7, Double(bounds.minX))
            sqlite3_bind_double(insert, 8, Double(bounds.minY))
            sqlite3_bind_double(insert, 9, Double(bounds.width))
            sqlite3_bind_double(insert, 10, Double(bounds.height))
        }
        try step(db: db, sql: insertNodeSQL, statement: insert)
        let nodeId = sqlite3_last_insert_rowid(db)
        newNodeCount += 1

        if !childIds.isEmpty {
            let insertChildSQL = "INSERT INTO ax_node_child (parentId, position, childId) VALUES (?, ?, ?);"
            if statements.insertChild == nil {
                try prepare(db: db, sql: insertChildSQL, statement: &statements.insertChild)
            }
            for (position, childId) in childIds.enumerated() {
                sqlite3_reset(statements.insertChild)
                sqlite3_bind_int64(statements.insertChild, 1, nodeId)
                sqlite3_bind_int64(statements.insertChild, 2, Int64(position))
                sqlite3_bind_int64(statements.insertChild, 3, childId)
                try step(db: db, sql: insertChildSQL, statement: statements.insertChild)
            }
        }

        return nodeId
    }

    // MARK: - SQLite helpers

    private static func prepare(db: OpaquePointer, sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func step(db: OpaquePointer, sql: String, statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func exec(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorPointer)
            throw DatabaseError.queryFailed(query: sql, underlying: message)
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }
}
