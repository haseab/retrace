# Contributing to Retrace

Thank you for your interest in contributing to Retrace! This document provides guidelines and instructions for contributing to this local-first screen recording and search application for macOS.

## Table of Contents

- [AI-Assisted Development](#ai-assisted-development)
- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Project Architecture](#project-architecture)
- [Development Workflow](#development-workflow)
- [Testing Requirements](#testing-requirements)
- [Coding Standards](#coding-standards)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Module Ownership](#module-ownership)

## AI-Assisted Development

**Retrace embraces AI-assisted development tools** like Claude Code, Cursor, GitHub Copilot, and similar coding assistants. We encourage contributors to use these tools to improve productivity and code quality.

### AGENTS.md Standard

This project follows the **[AGENTS.md](https://agents.md)** specification—an open, vendor-agnostic standard for AI agent guidance gaining industry-wide adoption:

- **What it is**: A "README for agents" separate from human-focused documentation
- **Why we use it**: Provides predictable, structured instructions for AI coding assistants
- **Industry backing**: Supported by the Agentic AI Foundation (Linux Foundation), with participation from OpenAI, Anthropic, Google, AWS, Microsoft, and others
- **Location**:
  - Root-level: [AGENTS.md](AGENTS.md) - Project-wide guidance
  - Module-level: `{Module}/AGENTS.md` - Module-specific instructions

**For AI tools**: The AGENTS.md files are designed for you. Read them first before generating code.

**For humans**: While AGENTS.md is agent-focused, it's also useful for understanding project structure and conventions. For getting-started information, see [README.md](README.md).

### Using AI Tools Effectively

When using AI coding assistants (Claude Code, Cursor, Copilot, etc.):

#### 1. **Point AI to Project Documentation**

Before generating code, ensure your AI assistant has read:

```
# Essential reading for AI assistants
CONTRIBUTING.md          ← You are here (coding standards, testing requirements)
RETRACE_GUIDE.md        ← Full technical specification
AGENTS.md               ← Architecture overview and module rules (industry standard)
{Module}/AGENTS.md      ← Module-specific guidelines (e.g., Database/AGENTS.md)
{Module}/README.md      ← Implementation details for the module you're working on
```

**Example prompts for Cursor/Claude Code:**

```
"Read CONTRIBUTING.md and Database/AGENTS.md, then help me implement
a new migration following the project's coding standards and TDD approach"

"Following the guidelines in AGENTS.md, write tests first for
a new search ranking algorithm in the Search module"

"Review this code against the standards in CONTRIBUTING.md and AGENTS.md
and suggest improvements"
```

#### 2. **Follow Test-Driven Development (TDD)**

When asking AI to generate code:

```
✅ GOOD: "Write tests first for a function that deduplicates frames,
         then implement it following TDD"

❌ BAD: "Write a frame deduplication function"
```

AI assistants should:

- Generate **tests first** (RED)
- Then implement **minimal code** to pass (GREEN)
- Finally suggest **refactoring** if needed (REFACTOR)

#### 3. **Request Adherence to Project Standards**

Be explicit about following project conventions:

```
"Generate a DatabaseManager method following:
- Swift async/await patterns from CONTRIBUTING.md
- Error handling using DatabaseError types from Shared/Models/Errors.swift
- Parameterized SQL queries (no string interpolation)
- Actor isolation for thread safety
- Documentation comments for public APIs"
```

#### 4. **Module Boundaries**

Remind AI tools about module isolation:

```
"I'm working in the Search module. Only import from Shared/,
never from Database/ or Storage/ directly. Use protocols from
Shared/Protocols/SearchProtocol.swift"
```

#### 5. **Review AI-Generated Code**

**Always review** AI-generated code for:

- [ ] Follows project coding standards
- [ ] Uses correct error types from `Shared/Models/Errors.swift`
- [ ] Includes tests (TDD approach)
- [ ] Handles edge cases (unicode, nulls, boundaries)
- [ ] Uses async/await properly
- [ ] Thread-safe (actors/Sendable)
- [ ] No hardcoded values (use config)
- [ ] Proper documentation

### AI Tool Configuration

#### Configuration Files for Different AI Tools

**AGENTS.md Standard**: All tools benefit from the industry-standard `AGENTS.md` files (already present)

**Cursor**: Create a `.cursorrules` file in the project root (or point to AGENTS.md)

**Claude Code**: Automatically reads `AGENTS.md` and `{Module}/AGENTS.md` files

**GitHub Copilot**: Create a `.github/copilot-instructions.md` file (or point to AGENTS.md)

**Codex**: Uses `.cursorrules`

All tools benefit from the same core rules defined in AGENTS.md:

```markdown
# Retrace Project Rules

## Architecture

- Modular architecture with strict module boundaries
- Only import from Shared/ module
- Use protocols for all cross-module communication

## Code Style

- Swift 5.9+ with async/await
- Use actors for stateful types
- All public types must be Sendable
- Prefer value types (structs) over classes

## Testing

- Test-Driven Development (TDD) required
- Write tests BEFORE implementation
- Cover edge cases: empty, null, unicode, boundaries

## Documentation to Read

Before generating code, consult:

- CONTRIBUTING.md - Coding standards
- RETRACE_GUIDE.md - Technical spec
- AGENTS.md - Architecture overview (industry standard)
- {Module}/AGENTS.md - Module-specific rules

## Error Handling

Use specific error types from Shared/Models/Errors.swift:

- DatabaseError
- StorageError
- CaptureError
- ProcessingError
- SearchError

## Security

- Never log sensitive data
- Use parameterized SQL queries
- Encrypt data at rest
- Request permissions gracefully
```

#### Tool-Specific Setup

**For Claude Code:**

- Already configured! Claude Code automatically reads:
  - `AGENTS.md` - Main project instructions (industry standard)
  - `{Module}/AGENTS.md` - Module-specific agent instructions
  - This `CONTRIBUTING.md` file
- Simply reference these files in your prompts:
  ```
  "Following the TDD approach from CONTRIBUTING.md and AGENTS.md, help me..."
  ```

**For Cursor:**

- **Recommended**: Create `.cursorrules` that points to AGENTS.md:
  ```
  Please read AGENTS.md and {Module}/AGENTS.md for complete project guidance.
  ```
- Alternatively, duplicate the rules from AGENTS.md (not recommended - creates maintenance burden)
- Cursor reads this on every session

**For GitHub Copilot:**

- **Recommended**: Create `.github/copilot-instructions.md` that points to AGENTS.md:
  ```markdown
  # GitHub Copilot Instructions

  Please read the following files for complete project guidance:
  - AGENTS.md - Project-wide standards and architecture
  - {Module}/AGENTS.md - Module-specific instructions
  - CONTRIBUTING.md - Contribution guidelines
  ```
- GitHub Copilot workspace instructions (experimental feature)

**For Codex (OpenAI):**

- Can use `.cursorrules` (compatible format)
- Point to AGENTS.md as shown above
- Or configure via OpenAI API settings

**Important**: If you create tool-specific configuration files (`.cursorrules`, `.github/copilot-instructions.md`, etc.), **point them to AGENTS.md** rather than duplicating content. This ensures:
- Single source of truth (AGENTS.md)
- Consistent guidance across all AI tools
- Easy maintenance (update AGENTS.md, not multiple files)

### Best Practices

**DO:**

- ✅ Use AI to accelerate testing (generate comprehensive test cases)
- ✅ Ask AI to review code against project standards
- ✅ Use AI for boilerplate reduction (protocol conformance, etc.)
- ✅ Request explanations of complex code
- ✅ Generate documentation from code
- ✅ Refactor with AI assistance

**DON'T:**

- ❌ Blindly accept AI-generated code without review
- ❌ Skip tests because "AI wrote it"
- ❌ Ignore project standards because AI used different conventions
- ❌ Commit AI-generated code without understanding it
- ❌ Use AI to circumvent the review process

### Example Workflow

```bash
# 1. Start with a clear prompt referencing guidelines
$ cursor
"Read CONTRIBUTING.md and Database/AGENTS.md. I need to add a new
query method to DatabaseManager for searching frames by date range.
Use TDD - write tests first."

# 2. AI generates tests
# Review tests for completeness

# 3. AI implements the method
# Review implementation against coding standards

# 4. Run tests
$ swift test --filter testGetFramesByDateRange

# 5. Review and refine with AI
"The implementation passes tests but doesn't handle timezone edge cases.
Add tests and fix."

# 6. Commit with clear message
$ git commit -m "feat(database): add date range query for frames"
```

### AI-Specific Guidelines

When working with AI tools on Retrace:

1. **Context Window Management**: AI tools have limited context. Focus them on:

   - The module you're working in
   - Relevant protocol definitions from `Shared/`
   - Specific section of CONTRIBUTING.md needed

2. **Iterative Refinement**: Use AI for iteration:

   ```
   "This works but violates the 'no blocking I/O' rule in CONTRIBUTING.md.
   Convert to async/await."
   ```

3. **Documentation Generation**: AI excels at:

   - Generating inline documentation
   - Creating README updates
   - Writing test descriptions
   - Explaining complex algorithms

4. **Code Review**: Use AI as a pre-review:
   ```
   "Review this PR against CONTRIBUTING.md coding standards and
   suggest improvements before I submit for human review."
   ```

### Disclosure in PRs

When submitting PRs with AI assistance:

**You don't need to disclose** AI usage - we assume most code involves AI assistance.

**Do disclose** if:

- AI generated complex algorithms you're unsure about
- You need help understanding AI-generated code
- AI suggested an approach that conflicts with project guidelines

### Learn from AI

Use AI tools to **learn** project patterns:

```
"Show me examples of actor usage in the existing codebase"
"Explain how the DatabaseManager handles errors"
"What's the pattern for creating new migrations?"
```

This helps you understand the codebase better and contribute more effectively.

---

## Code of Conduct

This project follows standard open-source collaboration practices:

- **Be respectful** and considerate in all interactions
- **Be constructive** when providing feedback
- **Focus on the code**, not the person
- **Welcome newcomers** and help them get started

## Getting Started

### Prerequisites

- macOS 13.0+ (Ventura)
- Xcode 15.0+
- Swift 5.9+
- Apple Silicon recommended (for hardware encoding/Neural Engine)

### Initial Setup

1. **Clone the repository**

   ```bash
   git clone https://github.com/yourusername/retrace.git
   cd retrace
   ```

2. **Read the technical documentation**

   - [RETRACE_GUIDE.md](RETRACE_GUIDE.md) - Full technical specification
   - [AGENTS.md](AGENTS.md) - Project structure and module overview (industry standard)
   - Module-specific AGENTS.md and README files in each directory

3. **Build the project**

   ```bash
   swift build
   ```

4. **Run tests**
   ```bash
   swift test
   ```

## Project Architecture

Retrace uses a **modular architecture** with clear separation of concerns:

```
┌──────────────┐
│  App Layer   │ ← Integration & UI
├──────────────┤
│   Modules    │ ← Capture, Processing, Search
├──────────────┤
│   Storage    │ ← Database, Files, Encryption
├──────────────┤
│   Shared     │ ← Models, Protocols
└──────────────┘
```

### Key Modules

| Module         | Path          | Responsibility                      |
| -------------- | ------------- | ----------------------------------- |
| **Database**   | `Database/`   | SQLite, FTS5, schema, migrations    |
| **Storage**    | `Storage/`    | File I/O, HEVC encoding, encryption |
| **Capture**    | `Capture/`    | ScreenCaptureKit, deduplication     |
| **Processing** | `Processing/` | Vision OCR, Accessibility API       |
| **Search**     | `Search/`     | Query parsing, ranking, FTS queries |
| **Migration**  | `Migration/`  | Import from Rewind, etc.            |
| **Shared**     | `Shared/`     | Models, protocols, errors           |

### Critical Rules

1. **Stay in Your Lane**

   - Only modify files in your module's directory
   - Never modify `Shared/` without coordination
   - Don't create cross-module dependencies (use protocols)

2. **Depend Only on Protocols**

   - Import only from `Shared/`
   - Never import another module directly
   - Conform to protocols in `Shared/Protocols/`

3. **Use Shared Types**
   - All cross-module data uses types from `Shared/Models/`
   - Don't duplicate types
   - Propose new types via issue/PR discussion

## Development Workflow

### 1. Create an Issue First

Before starting work:

- Check existing issues and PRs
- Create an issue describing the feature/bug
- Wait for maintainer feedback (avoid duplicate work)

### 2. Fork and Branch

```bash
# Fork the repo on GitHub, then:
git clone https://github.com/YOUR_USERNAME/retrace.git
cd retrace

# Create a feature branch
git checkout -b feature/your-feature-name
# or
git checkout -b fix/issue-number-description
```

### Branch Naming

- `feature/` - New features
- `fix/` - Bug fixes
- `refactor/` - Code refactoring
- `docs/` - Documentation only
- `test/` - Test additions/fixes

### 3. Make Your Changes

Follow the [Testing Requirements](#testing-requirements) and [Coding Standards](#coding-standards).

### 4. Test Thoroughly

```bash
# Run all tests
swift test

# Run specific module tests
swift test --filter DatabaseTests
swift test --filter StorageTests

# Run specific test
swift test --filter testSearchWithFilters
```

### 5. Commit Your Changes

Follow [Commit Guidelines](#commit-guidelines).

### 6. Push and Create PR

```bash
git push origin feature/your-feature-name
```

Then create a Pull Request on GitHub.

## Testing Requirements

**Retrace follows Test-Driven Development (TDD)**. Tests are **mandatory** for all contributions.

### ⚠️ CRITICAL: Test with REAL Input Data, Not Fake Structures

**The Problem:**
Many tests "play cop and thief" - creating fake data structures and validating the fake data they created. This provides **zero confidence** about real system behavior.

**Example of USELESS Test:**
```swift
func testAccessibilityResultCreation() {
    let appInfo = AppInfo(bundleID: "com.apple.Safari", ...)  // WE CREATE THIS
    let result = AccessibilityResult(appInfo: appInfo, ...)
    XCTAssertEqual(result.appInfo.bundleID, "com.apple.Safari")  // WE VALIDATE WHAT WE CREATED
}
```

**Example of USEFUL Test:**
```swift
func testDatabaseSchemaExists() async throws {
    // REAL SQLite query
    let tables = try await database.getTables()
    // Validates ACTUAL schema in REAL database
    XCTAssertTrue(tables.contains("segment"))
}
```

**What Makes a Test Useful:**
1. ✅ Tests **real system APIs** (SQLite, FileManager, macOS Accessibility, Vision OCR)
2. ✅ Uses **real production input** (real screenshots, real audio, real OCR output)
3. ✅ Validates **end-to-end workflows** (screenshot → OCR → database → search)
4. ❌ **NOT** testing if Swift can assign struct fields
5. ❌ **NOT** testing string concatenation or boolean flags

**Testing Philosophy:**
- **Database tests**: Validate real SQLite behavior (SQL syntax, FTS5, migrations) ✅
- **Integration tests**: Use REAL input data (see `test_assets/` requirements) ✅
- **Avoid circular tests**: Don't create data and validate what you created ❌

See [TESTS_CLEANUP.md](TESTS_CLEANUP.md) and [TESTS_MIGRATION.md](TESTS_MIGRATION.md) for full details on test philosophy.

### The TDD Cycle

```
1. Write failing test (RED) - Use REAL input data
2. Write minimum code to pass (GREEN)
3. Refactor (REFACTOR)
4. Repeat
```

### Test Coverage Requirements

Every module **MUST** have these test categories:

| Category                     | Purpose                       | Example                      |
| ---------------------------- | ----------------------------- | ---------------------------- |
| **Schema/Config Validation** | Verify configuration is valid | SQL compiles, paths exist    |
| **Real API Tests**           | Test actual system APIs       | SQLite queries, Vision OCR   |
| **Edge Cases**               | Boundaries, nulls, errors     | Empty DB, unicode, injection |
| **Integration Tests**        | End-to-end workflows          | Real screenshot → database   |

### Real Input Data Requirements

For integration tests, use **real production data**:

```
test_assets/
├── screenshots/           # Real .png files
│   ├── monkeytype.png
│   ├── github_code.png
│   └── expected_ocr/*.json
├── audio/                 # Real .m4a files
│   ├── meeting_2speakers.m4a
│   └── expected_transcriptions/*.json
└── video/                 # Real screen recordings
    └── screen_1080p.mp4
```

**Why this matters:**
- ✅ Validates the FULL pipeline with real data
- ✅ Catches bugs that synthetic data misses
- ✅ Tests real Vision OCR behavior, not assumptions
- ❌ Synthetic/fake data only tests your test code

### Edge Cases to ALWAYS Test

- ✅ Empty state (no data)
- ✅ Null/nil optional fields
- ✅ Unicode and special characters (emoji, CJK, RTL)
- ✅ SQL injection attempts (for database)
- ✅ Boundary conditions (timestamps, limits)
- ✅ Duplicate handling
- ✅ Error conditions

### Writing Tests

```swift
// ✅ GOOD: Test with real system API
func testVisionOCRWithRealScreenshot() async throws {
    // Load REAL screenshot
    let screenshot = loadTestAsset("screenshots/monkeytype.png")

    // Run REAL Vision OCR
    let result = try await visionOCR.process(screenshot)

    // Validate REAL output
    XCTAssertTrue(result.text.contains("Monkeytype"))
    XCTAssertGreaterThan(result.regions.count, 5)
}

// ❌ BAD: Test with fake data
func testOCRResultCreation() {
    // We create fake OCR data
    let region = OCRRegion(text: "test", bounds: ...)
    // We validate what we created - proves nothing!
    XCTAssertEqual(region.text, "test")
}
```

### Test Checklist Before PR

- [ ] All existing tests pass
- [ ] New feature has tests
- [ ] Tests use REAL APIs or REAL input data (not fake structures)
- [ ] Edge cases covered
- [ ] Integration test if cross-module
- [ ] No circular "cop and thief" tests

## Coding Standards

### Swift Style Guide

Follow Apple's [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).

#### Key Conventions

**1. Naming**

```swift
// ✅ Clear, descriptive names
func searchDocuments(matching query: String) -> [SearchResult]
let captureIntervalSeconds: Double

// ❌ Unclear abbreviations
func srch(q: String) -> [Result]
let capInt: Double
```

**2. Access Control**

```swift
// Use minimum necessary access level
public protocol CaptureProtocol { }     // Module interface
internal class CaptureManager { }       // Implementation
private func validateConfig() { }       // Internal helper
```

**3. Concurrency (Swift 6 Ready)**

```swift
// ✅ Use actors for stateful types
actor DatabaseManager: DatabaseProtocol {
    private var db: OpaquePointer?

    func insertFrame(_ frame: FrameReference) async throws {
        // Thread-safe by default
    }
}

// ✅ Mark types as Sendable
public struct CapturedFrame: Sendable {
    public let imageData: Data
    public let timestamp: Date
}

// ✅ Use async/await
func extractText(from frame: CapturedFrame) async throws -> ExtractedText
```

**4. Error Handling**

```swift
// ✅ Use specific error types from Shared/Models/Errors.swift
throw DatabaseError.queryFailed(query: sql, underlying: message)
throw CaptureError.permissionDenied

// ❌ Don't use generic errors
throw NSError(domain: "error", code: 1)
```

**5. Value Types Over Classes**

```swift
// ✅ Prefer structs for data
public struct SearchQuery: Sendable {
    let text: String
    let limit: Int
}

// ⚠️ Only use classes/actors when needed
actor CaptureManager { }  // Needs state management
```

### Code Organization

**File Structure**

```swift
import Foundation
import Shared

// MARK: - Main Type

public actor MyManager: MyProtocol {
    // MARK: - Properties

    private var state: State

    // MARK: - Initialization

    public init() { }

    // MARK: - Public Methods

    public func publicMethod() async throws { }

    // MARK: - Private Helpers

    private func privateHelper() { }
}

// MARK: - Supporting Types

private struct State {
    // ...
}
```

### Documentation

**1. Public APIs**

```swift
/// Searches the full-text index for documents matching the query.
///
/// - Parameters:
///   - query: The search query with optional filters
/// - Returns: Search results sorted by relevance
/// - Throws: `SearchError.invalidQuery` if query is empty
public func search(query: SearchQuery) async throws -> SearchResults
```

**2. Complex Logic**

```swift
// Explain WHY, not WHAT
// Using BM25 ranking because it handles term frequency better than cosine similarity
let rankedResults = results.sorted { $0.rank > $1.rank }
```

**3. Avoid Obvious Comments**

```swift
// ❌ BAD: States the obvious
// Increment counter
counter += 1

// ✅ GOOD: Explains reasoning
// Skip duplicate frames to reduce storage (deduplication threshold: 0.98)
if similarity > config.deduplicationThreshold { continue }
```

### Performance Guidelines

**1. Prefer Async Over Blocking**

```swift
// ✅ GOOD
func processFrame(_ frame: CapturedFrame) async throws -> ExtractedText

// ❌ BAD
func processFrame(_ frame: CapturedFrame) throws -> ExtractedText {
    Thread.sleep(forTimeInterval: 2.0)  // Blocks thread
}
```

**2. Minimize Memory Allocations**

```swift
// ✅ GOOD: Reuse buffer
var buffer = [UInt8](repeating: 0, count: 1024)
for chunk in chunks {
    buffer.withUnsafeMutableBytes { ... }
}

// ❌ BAD: Allocates on every iteration
for chunk in chunks {
    let buffer = [UInt8](repeating: 0, count: 1024)
}
```

**3. Database Performance**

```swift
// ✅ GOOD: Use transactions for batch operations
try db.transaction {
    for doc in documents {
        try insertDocument(doc)
    }
}

// ❌ BAD: Individual transactions
for doc in documents {
    try insertDocument(doc)  // Slow!
}
```

## Commit Guidelines

### Commit Message Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

**Type** (required):

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code refactoring
- `test` - Adding tests
- `docs` - Documentation only
- `perf` - Performance improvement
- `style` - Code style (formatting, etc.)
- `chore` - Maintenance tasks

**Scope** (optional):

- Module name: `database`, `storage`, `capture`, `processing`, `search`
- Area: `tests`, `docs`, `build`

**Subject**:

- Brief description (50 chars or less)
- Imperative mood ("Add feature" not "Added feature")
- No period at the end

### Examples

```
feat(database): add migration for app_sessions table

Implement schema migration v2 to add the app_sessions table
for tracking continuous app usage periods.

- Create migration runner
- Add app_sessions schema
- Update DatabaseManager to run migrations on init

Closes #42
```

```
fix(capture): prevent crash when no displays available

Handle edge case where ScreenCaptureKit returns empty display
list (e.g., during display disconnect).

Fixes #103
```

```
test(search): add edge case tests for unicode queries

Add tests for:
- Emoji in search queries
- CJK characters
- RTL text (Arabic, Hebrew)
```

### Atomic Commits

Each commit should be a **single logical change**:

```bash
# ✅ GOOD: Separate commits
git commit -m "feat(database): add VideoSegment width/height fields"
git commit -m "test(database): update tests for new VideoSegment schema"

# ❌ BAD: Mixed changes
git commit -m "fix everything and add tests and refactor"
```

## Pull Request Process

### Before Submitting

1. **Rebase on latest main**

   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Run all tests**

   ```bash
   swift test
   ```

3. **Check code formatting**

   ```bash
   # Use SwiftFormat or SwiftLint if available
   swiftformat .
   swiftlint
   ```

4. **Update documentation**
   - Add/update README if needed
   - Update PROGRESS.md in your module
   - Add inline documentation for new public APIs

### PR Template

When creating a PR, include:

**Title**: Same format as commit messages

```
feat(capture): add app blacklist UI
```

**Description**:

```markdown
## Summary

Brief description of what this PR does.

## Changes

- Bullet list of specific changes
- Keep it concise

## Testing

How did you test this?

- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing performed

## Screenshots (if UI changes)

[Add screenshots here]

## Related Issues

Closes #123
Relates to #456

## Checklist

- [ ] Tests pass locally
- [ ] Documentation updated
- [ ] No new warnings
- [ ] Follows coding standards
```

### Review Process

1. **Automated checks** run (tests, lint)
2. **Maintainer review** (usually within 2-3 days)
3. **Address feedback** by pushing new commits
4. **Approval** from at least one maintainer
5. **Merge** (squash merge preferred for features)

### After Merge

- Delete your feature branch
- Pull latest main
- Close related issues

## Module Ownership

Each module has specific guidelines. Read the module-specific documentation:

| Module     | Agent Guide (AGENTS.md Standard)           | README                                       |
| ---------- | ------------------------------------------ | -------------------------------------------- |
| Database   | [Database/AGENTS.md](Database/AGENTS.md)   | [Database/README.md](Database/README.md)     |
| Storage    | [Storage/AGENTS.md](Storage/AGENTS.md)     | [Storage/README.md](Storage/README.md)       |
| Capture    | [Capture/AGENTS.md](Capture/AGENTS.md)     | [Capture/README.md](Capture/README.md)       |
| Processing | [Processing/AGENTS.md](Processing/AGENTS.md) | [Processing/README.md](Processing/README.md) |
| Search     | [Search/AGENTS.md](Search/AGENTS.md)       | [Search/README.md](Search/README.md)         |
| Migration  | [Migration/AGENTS.md](Migration/AGENTS.md) | [Migration/README.md](Migration/README.md)   |

### Module-Specific Rules

**Database Module**

- Must maintain backward compatibility for migrations
- All SQL must be parameterized (no string interpolation)
- Performance: queries should complete in <100ms

**Storage Module**

- All file operations must be encrypted by default
- Handle disk full gracefully
- Clean up temp files on error

**Capture Module**

- Respect system resources (<20% CPU)
- Handle permission denied gracefully
- Deduplication must be efficient

**Processing Module**

- OCR must complete in <500ms per frame
- Support multiple languages
- Handle low-quality images gracefully

**Search Module**

- Search must complete in <100ms
- Support complex query syntax
- Rank results by relevance

## Security Considerations

### Data Privacy

- **Never log sensitive data** (passwords, tokens, user content)
- **Encrypt data at rest** (video segments, database if implementing)
- **Use Keychain** for encryption keys
- **Respect user privacy settings** (excluded apps, private browsing)

### Code Security

```swift
// ✅ GOOD: Parameterized queries
let sql = "SELECT * FROM frames WHERE id = ?"
sqlite3_bind_text(stmt, 1, frameID.stringValue, -1, SQLITE_TRANSIENT)

// ❌ BAD: SQL injection vulnerability
let sql = "SELECT * FROM frames WHERE id = '\(frameID)'"
```

### Permission Handling

```swift
// ✅ GOOD: Request permissions gracefully
if !hasScreenRecordingPermission() {
    throw CaptureError.permissionDenied
}

// ❌ BAD: Crash on permission denied
let stream = SCStream(...)  // Crashes if no permission
```

## Performance Targets

Maintain these performance benchmarks:

| Metric         | Target           | Critical Threshold |
| -------------- | ---------------- | ------------------ |
| CPU Usage      | <20% single core | 50%                |
| Memory Usage   | <1GB total       | 2GB                |
| Search Latency | <100ms           | 500ms              |
| OCR Latency    | <500ms           | 2s                 |
| Storage Growth | ~15-20GB/month   | 50GB/month         |

## Getting Help

- **Documentation**: Start with [RETRACE_GUIDE.md](RETRACE_GUIDE.md)
- **Issues**: Check existing issues or create a new one
- **Discussions**: Use GitHub Discussions for questions
- **Code Review**: Don't hesitate to ask questions in PR comments

## License

By contributing to Retrace, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).

---

Thank you for contributing to Retrace! 🎉
