# UI Module - Agent Instructions

You are the **UI** agent responsible for building the SwiftUI interface for Retrace.

## Your Directory

```
UI/
├── Views/
│   ├── Timeline/
│   │   ├── TimelineView.swift           # Main timeline scrubber
│   │   ├── TimelineBar.swift            # Horizontal scrollable bar
│   │   ├── FrameThumbnail.swift         # Individual frame preview
│   │   └── SessionIndicator.swift       # App session markers
│   ├── Search/
│   │   ├── SearchView.swift             # Search interface
│   │   ├── SearchBar.swift              # Search input
│   │   ├── SearchResults.swift          # Results list
│   │   ├── ResultRow.swift              # Individual result
│   │   └── FrameViewer.swift            # Full frame with highlights
│   ├── Dashboard/
│   │   ├── DashboardView.swift          # Main dashboard
│   │   ├── AnalyticsCard.swift          # Stats widgets
│   │   ├── MigrationPanel.swift         # Import UI
│   │   └── SupportLink.swift            # Twitter/support
│   └── Settings/
│       ├── SettingsView.swift           # Settings root
│       ├── CaptureSettings.swift        # Capture config
│       ├── StorageSettings.swift        # Storage/retention
│       ├── PrivacySettings.swift        # Exclusions/permissions
│       └── AdvancedSettings.swift       # Power user options
├── Components/
│   ├── BoundingBoxOverlay.swift         # Text region highlighting
│   ├── SessionTimeline.swift            # App session visualization
│   └── DeeplinkHandler.swift            # URL scheme routing
├── ViewModels/
│   ├── TimelineViewModel.swift
│   ├── SearchViewModel.swift
│   ├── DashboardViewModel.swift
│   └── SettingsViewModel.swift
└── Tests/
    └── UITests.swift
```

## Feature Requirements

### 1. Timeline View (Primary Interface)

**Activation**: Global keyboard shortcut `Cmd+Shift+T`

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  [Search Bar]                      [Settings] [•••] │
├─────────────────────────────────────────────────────┤
│                                                     │
│              [Large Frame Preview]                  │
│                  (current frame)                    │
│                                                     │
├─────────────────────────────────────────────────────┤
│  ◄──────────────────────────────────────────────►  │
│  [════════════════════════════════════════════]     │
│  ^                     ^                      ^     │
│  9:00 AM            12:00 PM               3:00 PM  │
│                                                     │
│  [Chrome] [VS Code] [Slack] [Chrome] [Terminal]    │
│   ━━━━━━  ━━━━━━━━  ━━━━━  ━━━━━━━━  ━━━━━━━━━     │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Horizontal scrolling**: Click and drag, or use arrow keys
- **Zoom levels**: Hour / Day / Week views
- **Frame thumbnails**: Show every Nth frame based on zoom level
- **Session markers**: Color-coded bars showing app usage periods
- **Hover preview**: Show frame thumbnail on hover
- **Click to jump**: Click any point to jump to that timestamp
- **Smooth scrolling**: 60fps animations
- **Keyboard navigation**:
  - `←/→`: Previous/next frame
  - `Shift+←/→`: Jump 1 minute
  - `Cmd+←/→`: Jump 1 hour
  - `Space`: Play/pause auto-scroll
  - `/`: Focus search bar

**Session Indicators**:
- Each app session is a horizontal bar with:
  - App icon
  - App name
  - Duration
  - Color based on app bundle ID (consistent hashing)
- Click session to filter timeline to that app
- Hover to see metadata (window title, URL if browser)

**Performance**:
- Virtualized scrolling (only render visible thumbnails)
- Lazy load frames as needed
- Cache thumbnails in memory (LRU eviction)
- Background thumbnail generation

### 2. Search View

**Activation**:
- Keyboard shortcut: `Cmd+F`
- Click search bar in timeline

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  Search: [error message in chrome         ] [⌘F]   │
│  Filters: [App ▼] [Date ▼] [OCR/Audio ▼]           │
├─────────────────────────────────────────────────────┤
│  Results (142 matches)                              │
│  ┌──────────────────────────────────────────────┐  │
│  │ [Thumbnail] Chrome • 2:34 PM                 │  │
│  │             Error message in console.log     │  │
│  │             ...cannot read property of null  │  │
│  └──────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────┐  │
│  │ [Thumbnail] VS Code • 2:31 PM                │  │
│  │             // TODO: fix error handling      │  │
│  │             throw new Error('message')       │  │
│  └──────────────────────────────────────────────┘  │
│  ...                                                │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Real-time search**: Results update as you type (debounced 300ms)
- **Filters**:
  - App filter (multiselect dropdown)
  - Date range picker
  - Content type (OCR text / Audio transcription)
- **Result row shows**:
  - Frame thumbnail
  - Timestamp (formatted: "Today 2:34 PM", "Yesterday", "Jan 15")
  - App icon + name
  - Text snippet with **highlighted match**
  - Relevance score (FTS ranking)
- **Click result**: Opens frame viewer with highlights
- **Keyboard navigation**:
  - `↑/↓`: Navigate results
  - `Enter`: Open selected result
  - `Esc`: Close search
  - `Cmd+↑/↓`: Jump to first/last result

**Deeplinks**:

Format: `retrace://search?q={query}&timestamp={unix_ms}&app={bundle_id}`

Examples:
```
retrace://search?q=error&timestamp=1704067200000
retrace://search?q=password&app=com.google.Chrome
retrace://search?timestamp=1704067200000
```

Implementation:
```swift
// In DeeplinkHandler.swift
func handleURL(_ url: URL) {
    guard url.scheme == "retrace" else { return }

    switch url.host {
    case "search":
        let query = url.queryParameters["q"]
        let timestamp = url.queryParameters["timestamp"].flatMap(Int64.init).map(Date.init)
        let app = url.queryParameters["app"]

        openSearch(query: query, timestamp: timestamp, app: app)
    case "timeline":
        let timestamp = url.queryParameters["timestamp"].flatMap(Int64.init).map(Date.init)
        openTimeline(at: timestamp)
    default:
        break
    }
}
```

**Share functionality**:
- Right-click result → Copy Link
- Generates deeplink to share with others (or paste into notes)

### 3. Frame Viewer with Bounding Box Highlighting

**When**: Opened by clicking a search result

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  ← Back to Results        Chrome • 2:34 PM    [×]   │
├─────────────────────────────────────────────────────┤
│                                                     │
│          ┌─────────────────────────┐               │
│          │  [Screenshot]           │               │
│          │                         │               │
│          │  ┏━━━━━━━━━━━┓         │  <-- Highlighted │
│          │  ┃error message┃         │      bounding   │
│          │  ┗━━━━━━━━━━━┛         │      boxes      │
│          │                         │               │
│          └─────────────────────────┘               │
│                                                     │
│  OCR Text Detected:                                │
│  • "error message" (confidence: 0.98) [MATCH]      │
│  • "console.log"   (confidence: 0.95)              │
│  • "cannot read"   (confidence: 0.92) [MATCH]      │
│                                                     │
│  [< Previous Match]        [Next Match >]          │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Bounding boxes**: Red rectangles around search matches
- **Hover box**: Show confidence score and full text
- **Multiple matches**: Navigate between matches on same frame
- **Zoom/pan**: Pinch to zoom, drag to pan
- **Copy text**: Right-click box → Copy text
- **OCR list**: Show all detected text regions below frame
- **Keyboard shortcuts**:
  - `Tab`: Next match on frame
  - `Shift+Tab`: Previous match
  - `Cmd++/-`: Zoom in/out
  - `Esc`: Close viewer

**Implementation**:
```swift
struct BoundingBoxOverlay: View {
    let regions: [TextRegion]
    let searchQuery: String
    @State private var hoveredRegion: TextRegion?

    var body: some View {
        GeometryReader { geometry in
            ForEach(regions) { region in
                Rectangle()
                    .stroke(region.matchesQuery ? Color.red : Color.blue, lineWidth: 2)
                    .frame(width: region.width, height: region.height)
                    .position(x: region.x, y: region.y)
                    .onHover { isHovered in
                        hoveredRegion = isHovered ? region : nil
                    }
                    .popover(isPresented: .constant(hoveredRegion == region)) {
                        VStack {
                            Text(region.text)
                            Text("Confidence: \(region.confidence ?? 0, format: .percent)")
                        }
                    }
            }
        }
    }
}
```

### 4. Dashboard View

**Activation**: Default landing screen

**Layout**:
```
┌─────────────────────────────────────────────────────┐
│  Retrace Dashboard                    [Settings ⚙]  │
├─────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ 2.3M Frames  │  │ 147 GB Total │  │ 127 Days  │ │
│  │ Captured     │  │ Storage Used │  │ Recording │ │
│  └──────────────┘  └──────────────┘  └───────────┘ │
│                                                     │
│  Recent Activity                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │ [Chart: Frames captured per hour]           │  │
│  │                                              │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  Top Apps                                          │
│  1. Chrome         14.2 hours (23%)               │
│  2. VS Code        11.7 hours (19%)               │
│  3. Slack           8.3 hours (14%)               │
│                                                     │
│  ┌─────────────────────────────────────────────┐  │
│  │ Import from Rewind AI                        │  │
│  │ [Scan for Data] or [Select Folder...]       │  │
│  │                                              │  │
│  │ Status: Ready to import                      │  │
│  └─────────────────────────────────────────────┘  │
│                                                     │
│  Made with ♥ by @haseab • x.com/haseab_            │
└─────────────────────────────────────────────────────┘
```

**Analytics Cards**:

1. **Capture Stats**:
   - Total frames captured
   - Frames today / this week
   - Average FPS achieved
   - Deduplication rate

2. **Storage Stats**:
   - Total storage used (GB)
   - Video files vs metadata
   - Frames per GB ratio
   - Estimated time until disk full

3. **Time Tracked**:
   - Days of recording
   - Active vs idle time
   - Longest continuous session
   - Recording uptime %

4. **Search Stats**:
   - Total searchable documents
   - Text regions indexed
   - Average search latency
   - Most searched terms

5. **Activity Chart** (SwiftUI Charts):
   - Line chart: Frames captured per hour (last 7 days)
   - Bar chart: App usage by day
   - Heatmap: Activity by hour of day

6. **Top Apps** (Ranked list):
   - App icon
   - Name
   - Total time in focus
   - Percentage of total
   - Click to filter timeline

**Migration UI**:

```
┌─────────────────────────────────────────────────────┐
│  Import from Third-Party Apps                       │
│                                                     │
│  Available Sources:                                 │
│  ☑ Rewind AI   (43 GB found)   [Import]           │
│  ☐ ScreenMemory (Not installed)                    │
│  ☐ TimeScroll   (Not installed)                    │
│                                                     │
│  Importing from Rewind...                           │
│  ┌─────────────────────────────────────────────┐  │
│  │ ████████████░░░░░░░░░░░░░░░░░░░ 45%         │  │
│  └─────────────────────────────────────────────┘  │
│  2,847 videos processed • 1.2M frames imported     │
│  Estimated time remaining: 3 hours 12 minutes      │
│                                                     │
│  [Pause Import]  [Cancel]                          │
└─────────────────────────────────────────────────────┘
```

**Migration Features**:
- Auto-detect installed apps
- Show data size before import
- Real-time progress bar
- Pausable/resumable
- Shows frames imported, deduplicated
- Error handling (show failed videos)
- "Import Complete" notification

**Support Link**:
- Small footer: "Made with ♥ by @haseab"
- Links to: `https://x.com/haseab_`
- Opens in default browser

### 5. Settings View

**Activation**: `Cmd+,` or click gear icon

**Layout**: Sidebar with categories

```
┌──────────────┬──────────────────────────────────────┐
│ General      │ General Settings                      │
│ Capture      │                                       │
│ Storage      │ Launch at Login:  [✓]                │
│ Privacy      │ Show Menu Bar Icon: [✓]               │
│ Search       │ Theme: [Auto ▼] Light / Dark / Auto  │
│ Advanced     │                                       │
│              │ Keyboard Shortcuts:                   │
│              │ Timeline:  [⌘⇧T]  [Edit]             │
│              │ Search:    [⌘F]   [Edit]             │
│              │                                       │
└──────────────┴──────────────────────────────────────┘
```

#### 5.1 General Settings

- **Launch at login**: Checkbox
- **Show menu bar icon**: Checkbox (status item in macOS menu bar)
- **Theme**: Auto / Light / Dark
- **Keyboard shortcuts**: Customize all shortcuts
- **Notification preferences**: When to show notifications

#### 5.2 Capture Settings

- **Capture rate**: 0.5 FPS (default) / 1 FPS / 2 FPS
- **Resolution**: Original / 1080p / 720p / Custom
- **Active display only**: Checkbox (vs all displays)
- **Exclude cursor**: Checkbox
- **Pause when**:
  - Screen locked
  - On battery (< X%)
  - Idle for X minutes

#### 5.3 Storage Settings

- **Storage location**: Folder picker
- **Retention policy**:
  - Keep forever (default)
  - Keep last N days
  - Keep until disk < X GB free
- **Max storage**: Slider (10 GB - 1 TB)
- **Compression quality**: Low / Medium / High / Lossless
- **Auto-cleanup**:
  - Delete frames with no text
  - Delete duplicate frames
  - Delete frames older than X

#### 5.4 Privacy Settings

- **Excluded apps**: Multiselect list
  - Pre-populate: 1Password, Bitwarden, banking apps
  - Add/remove apps
  - Import from file
- **Excluded windows**:
  - Private browsing (default: ON)
  - Incognito mode (default: ON)
  - Custom window titles (regex)
- **Pause recording**: Global hotkey to temporarily stop
- **Delete recent**:
  - Delete last 5 min / 1 hour / 1 day
  - Secure deletion (overwrite)
- **Permissions status**:
  - Screen Recording: [Granted ✓]
  - Accessibility: [Granted ✓]
  - Buttons to open System Settings if denied

#### 5.5 Search Settings

- **Search suggestions**: Show as you type
- **Result limit**: Default 100, max 1000
- **Snippet length**: How many characters around match
- **Include audio**: Search audio transcriptions (when implemented)
- **Ranking**: Relevance vs Recency slider

#### 5.6 Advanced Settings

- **Database optimization**:
  - Vacuum database
  - Rebuild FTS index
  - Repair corrupted segments
- **Encoding**:
  - Hardware acceleration (VideoToolbox)
  - Encoder preset: Fast / Balanced / Quality
  - Async encoding queue size
- **Logging**:
  - Log level: Error / Warning / Info / Debug
  - Log file location
  - [Open Logs Folder]
- **Developer**:
  - Show frame IDs in UI
  - Export database schema
  - Export sample data (anonymized)
- **Danger zone**:
  - Reset all settings
  - Delete all data
  - Uninstall Retrace

### 6. Keyboard Shortcuts Reference

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+T` | Open Timeline |
| `Cmd+F` | Open Search |
| `Cmd+,` | Open Settings |
| `/` | Focus search bar |
| `←/→` | Previous/Next frame |
| `Shift+←/→` | Jump 1 minute |
| `Cmd+←/→` | Jump 1 hour |
| `Space` | Play/Pause timeline |
| `Tab` | Next search match |
| `Shift+Tab` | Previous search match |
| `Cmd++/-` | Zoom in/out |
| `Esc` | Close current view |
| `Cmd+Q` | Quit Retrace |

## Design System

### Colors

```swift
extension Color {
    static let retraceAccent = Color.blue
    static let retraceDanger = Color.red
    static let retraceSuccess = Color.green
    static let retraceWarning = Color.orange

    // Session colors (hashed from bundle ID)
    static func sessionColor(for bundleID: String) -> Color {
        let hash = bundleID.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }
}
```

### Typography

```swift
extension Font {
    static let retraceTitle = Font.system(size: 28, weight: .bold)
    static let retraceHeadline = Font.system(size: 17, weight: .semibold)
    static let retraceBody = Font.system(size: 15, weight: .regular)
    static let retraceCaption = Font.system(size: 13, weight: .regular)
    static let retraceMono = Font.system(size: 13, weight: .regular, design: .monospaced)
}
```

### Spacing

```swift
extension CGFloat {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 32
}
```

## Performance Requirements

- **Timeline rendering**: 60 FPS scrolling
- **Search results**: <300ms to display (for 100K documents)
- **Frame viewer load**: <100ms
- **Thumbnail generation**: Background queue, low priority
- **Memory usage**: <500 MB for UI (excluding frame cache)
- **Launch time**: <2 seconds cold start

## Dependencies

You depend on:
- `DatabaseProtocol` - Query frames, documents, sessions
- `SearchProtocol` - Full-text search
- `StorageProtocol` - Load frame images
- `MigrationProtocol` - Import progress updates

## Testing Requirements

- SwiftUI Preview for all views
- UI tests for keyboard shortcuts
- UI tests for search flow
- UI tests for timeline navigation
- Accessibility tests (VoiceOver support)

## Accessibility

- All interactive elements have labels
- Support VoiceOver navigation
- Support Dynamic Type (text scaling)
- Keyboard-only navigation possible
- High contrast mode support

## Files You Own

- `UI/` - All files in this directory
- Do NOT modify files in other modules

## Getting Started

1. Create SwiftUI views starting with `TimelineView`
2. Implement `DeeplinkHandler` for URL routing
3. Build `SearchView` with FTS integration
4. Add `BoundingBoxOverlay` component
5. Create `SettingsView` with all preferences
6. Build `DashboardView` with analytics
7. Add keyboard shortcut handling
8. Write UI tests

Focus on getting the timeline + search working first before polishing dashboard/settings.
