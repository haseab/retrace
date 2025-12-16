# Database Module

**Owner**: DATABASE Agent
**Instructions**: See [CLAUDE-DATABASE.md](../CLAUDE-DATABASE.md)

## Responsibility

SQLite database operations including:
- Schema definition and migrations
- Frame and segment CRUD operations
- Full-text search (FTS5) indexing
- Document storage for search

## Files to Create

```
Database/
├── DatabaseManager.swift      # Main DatabaseProtocol implementation
├── FTSManager.swift           # FTSProtocol implementation
├── Schema.swift               # Table definitions
├── Migrations/
│   ├── MigrationRunner.swift
│   └── V1_InitialSchema.swift
├── Queries/
│   ├── FrameQueries.swift
│   ├── SegmentQueries.swift
│   └── DocumentQueries.swift
└── Tests/
    ├── DatabaseManagerTests.swift
    └── FTSManagerTests.swift
```

## Protocols to Implement

- `DatabaseProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
- `FTSProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
