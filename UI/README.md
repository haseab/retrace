# UI Module

**Owner**: UI Agent (built after core modules)
**Status**: Future work

## Responsibility

SwiftUI user interface including:
- Timeline view for browsing history
- Search interface
- Video playback
- Settings and preferences
- Menu bar integration

## Files to Create

```
UI/
├── Timeline/
│   ├── TimelineView.swift
│   ├── TimelineViewModel.swift
│   ├── ThumbnailView.swift
│   └── TimelineControls.swift
├── Search/
│   ├── SearchView.swift
│   ├── SearchViewModel.swift
│   ├── SearchResultRow.swift
│   └── SearchFiltersView.swift
├── Playback/
│   ├── PlaybackView.swift
│   ├── PlaybackViewModel.swift
│   ├── VideoPlayer.swift
│   └── TextOverlay.swift
├── Settings/
│   ├── SettingsView.swift
│   ├── CaptureSettingsView.swift
│   ├── StorageSettingsView.swift
│   └── PrivacySettingsView.swift
├── MenuBar/
│   ├── MenuBarView.swift
│   └── StatusItemManager.swift
└── Common/
    ├── AppTheme.swift
    └── Styles.swift
```

## Key Features

1. **Timeline View**
   - Horizontal scrubbing through history
   - Thumbnail previews
   - Date/time navigation
   - App activity indicators

2. **Search View**
   - Global hotkey activation
   - Real-time search results
   - Filter by app, date range
   - Highlighted snippets

3. **Playback View**
   - Frame-by-frame navigation
   - Text selection overlay (VisionKit)
   - Copy text from any frame
   - Jump to search results

4. **Menu Bar**
   - Recording status indicator
   - Quick pause/resume
   - Open search shortcut

## Dependencies

Depends on ALL other modules:
- Search (for search functionality)
- Storage (for frame retrieval and playback)
- Database (for timeline data)
- Capture (for status and controls)
