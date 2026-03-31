# UI Module - Agent Instructions

You are the **UI** agent responsible for building the SwiftUI interface for Retrace.

**Status**: ✅ Fully implemented with modern SwiftUI design. Timeline, dashboard, search, settings, onboarding, feedback, and bundled crash-recovery helper integration all working. Global hotkeys functional (Cmd+Shift+T for timeline, Cmd+Shift+D for dashboard). Menu bar integration complete. **Apple Silicon required**. Audio transcription UI not implemented (planned for future release).

## Your Directory

```
UI/
├── Assets.xcassets/
│   ├── AppIcon.appiconset/             # App icon assets
│   ├── CreatorProfile.imageset/        # Creator profile image shown in onboarding/milestones
│   ├── InPageURLInstructions.imageset/ # Settings screenshot for Chromium browser in-page URL setup
│   ├── SafariInPageURLMenu.imageset/   # Safari screenshot: open Develop > Developer Settings
│   ├── SafariInPageURLToggle.imageset/ # Safari screenshot: enable Allow JavaScript from Apple Events
│   └── SafariInPageURLAllow.imageset/  # Safari screenshot: confirmation dialog with Allow button
├── Views/
│   ├── Timeline/
│   │   ├── TimelineView.swift           # Main timeline scrubber
│   │   ├── TimelineBar.swift            # Horizontal scrollable bar
│   │   ├── FrameThumbnail.swift         # Individual frame preview
│   │   └── SessionIndicator.swift       # App session markers
│   ├── FullscreenTimeline/
│   │   ├── SpotlightSearchOverlay.swift # Primary search overlay UI
│   │   ├── SearchFilterBar.swift        # Search filters and controls
│   │   ├── CommentComposerChrome.swift  # Shared header/button/chip/editor chrome for timeline and quick-comment composers
│   │   ├── CommentContextPreviewCard.swift # Shared context-preview card used by timeline and quick-comment composers
│   │   ├── StandaloneCommentComposerWindowController.swift # Floating quick-comment window controller
│   │   └── StandaloneQuickCommentView.swift # Dedicated standalone quick-comment UI
│   ├── Dashboard/
│   │   ├── DashboardView.swift          # Main dashboard
│   │   ├── ChangelogView.swift          # Appcast-powered release notes view
│   │   ├── AnalyticsCard.swift          # Stats widgets
│   │   ├── MigrationPanel.swift         # Import UI
│   │   └── SupportLink.swift            # Twitter/support
│   ├── Feedback/
│   │   ├── FeedbackFormView.swift       # Feedback sheet with form, sending, and success states
│   │   ├── FeedbackDiagnosticsPresentation.swift # Feedback diagnostics section building + readable formatting helpers
│   │   ├── FeedbackModels.swift         # Feedback launch context, diagnostics, and payload models
│   │   ├── FeedbackSubmissionExport.swift # Feedback export text/JSON generation + filtered payload builder
│   │   └── FeedbackService.swift        # Feedback submission and export implementation
│   └── Settings/
│       ├── SettingsView.swift           # Thin settings shell hosting navigation, alerts, and top-level wiring
│       ├── SettingsSidebar.swift        # Sidebar navigation + content header
│       ├── SettingsSearchOverlay.swift  # Cmd+K overlay and card routing
│       ├── SettingsDefaults.swift       # Shared settings defaults + master-key setup support types
│       ├── SettingsTab.swift            # Tab metadata and reset routing
│       ├── SettingsSearchEntry.swift    # Search index entry model
│       ├── SettingsSearchField.swift    # AppKit-backed search field
│       ├── SettingsShortcutCaptureField.swift # Global shortcut recorder
│       ├── SettingsCard.swift           # Shared settings card container
│       ├── ExcludedAppChip.swift        # App exclusion chip
│       ├── RetentionAppsChip.swift      # Retention app exclusion chip
│       ├── RetentionTagsChip.swift      # Retention tag exclusion chip
│       ├── FlowLayout.swift             # Flow layout helper for settings chips
│       ├── DatabaseSchemaView.swift     # Database schema sheet content
│       ├── InPageURLInstructionViews.swift # Reusable in-page URL instructions UI
│       └── Sections/
│           ├── GeneralSettingsView.swift
│           ├── GeneralSettingsActions.swift
│           ├── CaptureSettingsView.swift
│           ├── CaptureSettingsActions.swift
│           ├── InPageURLCollectionSettingsView.swift
│           ├── InPageURLTargetSettingsActions.swift
│           ├── InPageURLVerificationSettingsActions.swift
│           ├── InPageURLVerificationScriptActions.swift
│           ├── StorageSettingsView.swift
│           ├── ExportDataSettingsView.swift
│           ├── PrivacySettingsView.swift
│           ├── PrivacyMasterKeyActions.swift
│           ├── PrivacySettingsActions.swift
│           ├── PhraseLevelRedactionSettingsView.swift
│           ├── PrivateModeAutomationSettingsView.swift
│           ├── PowerSettingsView.swift
│           ├── TagManagementSettingsView.swift
│           ├── AdvancedSettingsView.swift
│           ├── SettingsFeedbackActions.swift
│           ├── SettingsUtilityActions.swift
│           └── SettingsLaunchAndResetActions.swift
├── CrashRecoveryHelper/
│   └── main.swift                       # Bundled launch-agent XPC helper supervising unexpected app termination
├── CrashRecoverySupport/
│   └── CrashRecoverySupport.swift       # Shared crash-recovery constants, disconnect suppression, and XPC protocol
├── LaunchAgents/
│   └── io.retrace.app.crash-recovery.plist # SMAppService launch-agent plist for crash recovery
├── Components/
│   ├── MasterKeyRedactionFlowCoordinator.swift # Shared missing-master-key prompt/recovery coordinator
│   ├── BoundingBoxOverlay.swift         # Text region highlighting
│   ├── CrashRecoveryManager.swift       # App-side SMAppService/XPC lifecycle manager
│   ├── SessionTimeline.swift            # App session visualization
│   ├── DeeplinkHandler.swift            # URL scheme routing
│   ├── LaunchMenuRouting.swift          # Shared dashboard/timeline/settings/system-monitor routing and frontmost-window checks for app/status menus
│   ├── AppMetadataCache.swift           # App name/icon lookup caches and app icon view
│   ├── FaviconProvider.swift            # Favicon memory+disk cache and favicon view
│   ├── ProcessCPUMonitor.swift          # Shared process CPU+memory sampler + 24h aggregation service
│   ├── ProcessMemoryCardPresentation.swift # Local presentation controller + row builder for memory monitor card
│   ├── ProcessMonitorModels.swift       # System Monitor snapshot/models + ranking/build helpers
│   ├── HoverLatchedScrollMonitor.swift  # Shared nested-scroll latch helper for hover-routed inner scroll regions
│   ├── ProcessCPUSummaryCard.swift      # System Monitor CPU table/card UI
│   ├── ProcessMemorySummaryCard.swift   # System Monitor memory table/card UI
│   ├── RetraceAboutPanel.swift          # Custom About panel content and window factory used by the app menu
│   └── UIMemoryEstimators.swift         # Shared UI memory-estimation helpers for telemetry
├── ViewModels/
│   ├── SimpleTimelineViewModel.swift    # Fullscreen timeline state, caching, playback, filters, OCR overlays
│   ├── SearchViewModel.swift
│   ├── DashboardViewModel.swift
│   ├── CrashRecoveryBannerModel.swift   # Dashboard-facing banner state derived from crash recovery manager status
│   ├── CommentComposerTargetDisplayInfo.swift # Shared display metadata/title logic for timeline and quick-comment composers
│   ├── FeedbackViewModel.swift          # Feedback form state, diagnostics, export, submission
│   ├── FeedbackSubmissionProgress.swift # Feedback submission stage copy/progress metadata
│   ├── QuickCommentComposerViewModel.swift # Standalone quick-comment target, tag, attachment, and submit state
│   ├── SettingsViewModel.swift
│   └── Settings/
│       ├── SettingsShellViewModel.swift
│       ├── GeneralSettingsViewModel.swift
│       ├── CaptureSettingsViewModel.swift
│       ├── InPageURLSettingsViewModel.swift
│       ├── StorageSettingsViewModel.swift
│       ├── PrivacySettingsViewModel.swift
│       ├── PowerSettingsViewModel.swift
│       ├── TagsSettingsViewModel.swift
│       └── AdvancedSettingsViewModel.swift
└── Tests/
    ├── BuildInfoAndUpdaterTests.swift    # Build metadata formatting + updater version fallback tests
    ├── CommentComposerTargetContextTests.swift # Comment-target utilities and quick-comment persisted-preview source coverage
    ├── CrashRecoverySupportTests.swift   # Crash-recovery bundle resolution and registration policy coverage
    ├── CrashReportSupportTests.swift     # Dashboard crash/WAL report discovery and launch-context coverage
    ├── QuitConfirmationPresentationTests.swift # Quit alert anchor-window selection coverage
    ├── FeedbackExportTests.swift         # Feedback report export formatting coverage
    ├── FeedbackSubmissionProgressTests.swift # Feedback sending-state sequence coverage
    ├── HyperlinkMappingTests.swift       # Stored hyperlink row to OCR-node mapping coverage
    ├── FaviconProviderTests.swift        # Favicon memory-vs-disk cache behavior coverage
    ├── HyperlinkResolutionTests.swift    # Hyperlink parsing/resolution coverage
    ├── InPageURLSettingsTests.swift      # In-page URL setup instructions and toggle coverage
    ├── MilestoneCelebrationViewTests.swift # Milestone dialog action layout coverage
    ├── OnboardingAutomationTargetTests.swift # Onboarding/settings unsupported browser coverage
    ├── AppNameResolverInstalledAppsTests.swift # Installed-app scan deduplication coverage
    ├── SearchViewModelAvailableAppsTests.swift # Search app-list merge/deduplication coverage
    ├── SpotlightSearchOverlayRecentEntryAppMapTests.swift # Recent entry app-name map deduplication coverage
    ├── Search/SearchPaginationCancellationTests.swift # Search stale-pagination cancellation coverage on mode/sort changes
    ├── DashboardAppUsageDateRangeTests.swift # Dashboard app-usage date-range normalization coverage
    ├── DateRangePresetShortcutTests.swift # Shared date-range preset shortcut mapping and inclusive-range coverage
    ├── CaptureIntervalSettingsTests.swift # Live capture-interval config update coverage
    ├── ProcessCPUDisplayMetricsTests.swift # CPU sampler display math and live ranking coverage
    ├── SearchHighlightTooltipTests.swift # Search highlight tooltip hover/dismiss coverage
    ├── Dashboard/                        # Dashboard-specific XCTestCase files (title formatting, storage tooltip breakdown)
    │   └── StorageTooltipBreakdownTests.swift # Storage chart tooltip breakdown coverage
    ├── MenuBar/                          # Menu bar interaction tests
    ├── Search/                           # Search/deeplink/overlay XCTestCase files
    ├── Settings/                         # Settings-focused XCTestCase files, including shell/view-model coverage
    ├── Support/                          # Shared XCTest helpers and support-only tests
    ├── SystemMonitor/                    # System monitor XCTestCase files
    ├── Timeline/TimelineCopyFeedbackTests.swift # Timeline copy image/text toast feedback coverage
    └── Timeline/                         # Timeline XCTestCase files
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

Format (canonical): `retrace://search?q={query}&t={unix_ms}&app={bundle_id}`
Legacy compatibility: `timestamp={unix_ms}` is also accepted.

Examples:
```
retrace://search?q=error&t=1704067200000
retrace://search?q=password&app=com.google.Chrome
retrace://search?timestamp=1704067200000
```

Implementation:
```swift
// In DeeplinkHandler.swift
func handleURL(_ url: URL) {
    guard url.scheme == "retrace" else { return }

    let params = url.queryParameters
    let timestampMs = params["t"] ?? params["timestamp"]   // support both keys
    let timestamp = timestampMs.flatMap(Int64.init).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }

    switch url.host {
    case "search":
        let query = params["q"]
        let app = params["app"]

        openSearch(query: query, timestamp: timestamp, app: app)
    case "timeline":
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

- SwiftUI Preview for views where a preview is practical
- Add UI tests for keyboard shortcuts, search flow, and timeline navigation when those behaviors change and can be exercised reliably
- Add accessibility tests when VoiceOver or keyboard navigation behavior changes and can be exercised reliably
- Do not add low-signal tests for insignificant visual polish or other non-behavioral edits

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
3. Build `SpotlightSearchOverlay` with FTS integration
4. Add `BoundingBoxOverlay` component
5. Create `SettingsView` with all preferences
6. Build `DashboardView` with analytics
7. Add keyboard shortcut handling
8. Add UI tests for behaviorally significant flows when warranted

Focus on getting the timeline + search working first before polishing dashboard/settings.
