import SwiftUI

@MainActor
final class SettingsShellViewModel: ObservableObject {
    @Published var selectedTab: SettingsTab
    @Published var hoveredTab: SettingsTab?
    @Published var pendingScrollTargetID: String?
    @Published var isScrollingToTarget = false
    @Published var isPauseReminderCardHighlighted = false
    @Published var isOCRCardHighlighted = false
    @Published var isOCRPrioritySliderHighlighted = false
    @Published var isTimelineScrollOrientationHighlighted = false
    @Published var showSettingsSearch = false
    @Published var settingsSearchQuery = ""
    @Published var showingSectionResetConfirmation = false

    private var pauseReminderHighlightTask: Task<Void, Never>?
    private var ocrCardHighlightTask: Task<Void, Never>?
    private var ocrPrioritySliderHighlightTask: Task<Void, Never>?
    private var timelineScrollOrientationHighlightTask: Task<Void, Never>?
    private var settingsSearchResetTask: Task<Void, Never>?

    init(initialTab: SettingsTab? = nil, initialScrollTargetID: String? = nil) {
        selectedTab = initialTab ?? .general
        pendingScrollTargetID = initialScrollTargetID
    }

    func cancelTransientTasks() {
        cancelPauseReminderHighlight()
        cancelOCRCardHighlight()
        cancelOCRPrioritySliderHighlight()
        cancelTimelineScrollOrientationHighlight()
        cancelSettingsSearchReset()
        showSettingsSearch = false
        settingsSearchQuery = ""
        hoveredTab = nil
        isScrollingToTarget = false
        pendingScrollTargetID = nil
        showingSectionResetConfirmation = false
    }

    func scheduleSettingsSearchReset() {
        cancelSettingsSearchReset()
        settingsSearchResetTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(200_000_000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            settingsSearchQuery = ""
            settingsSearchResetTask = nil
        }
    }

    func cancelSettingsSearchReset() {
        settingsSearchResetTask?.cancel()
        settingsSearchResetTask = nil
    }

    func triggerPauseReminderCardHighlight() {
        cancelPauseReminderHighlight()

        isPauseReminderCardHighlighted = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isPauseReminderCardHighlighted = true
            }
        }

        pauseReminderHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(1_800_000_000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isPauseReminderCardHighlighted = false
            }
            pauseReminderHighlightTask = nil
        }
    }

    func triggerTimelineScrollOrientationHighlight() {
        cancelTimelineScrollOrientationHighlight()

        isTimelineScrollOrientationHighlighted = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isTimelineScrollOrientationHighlighted = true
            }
        }

        timelineScrollOrientationHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(2_100_000_000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isTimelineScrollOrientationHighlighted = false
            }
            timelineScrollOrientationHighlightTask = nil
        }
    }

    func triggerOCRCardHighlight() {
        cancelOCRCardHighlight()

        isOCRCardHighlighted = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isOCRCardHighlighted = true
            }
        }

        ocrCardHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(1_800_000_000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isOCRCardHighlighted = false
            }
            ocrCardHighlightTask = nil
        }
    }

    func triggerOCRPrioritySliderHighlight() {
        cancelOCRPrioritySliderHighlight()

        isOCRPrioritySliderHighlighted = false
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.isOCRPrioritySliderHighlighted = true
            }
        }

        ocrPrioritySliderHighlightTask = Task { @MainActor in
            try? await Task.sleep(for: .nanoseconds(Int64(2_100_000_000)), clock: .continuous)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.38)) {
                isOCRPrioritySliderHighlighted = false
            }
            ocrPrioritySliderHighlightTask = nil
        }
    }

    private func cancelPauseReminderHighlight() {
        pauseReminderHighlightTask?.cancel()
        pauseReminderHighlightTask = nil
        isPauseReminderCardHighlighted = false
    }

    private func cancelOCRCardHighlight() {
        ocrCardHighlightTask?.cancel()
        ocrCardHighlightTask = nil
        isOCRCardHighlighted = false
    }

    private func cancelOCRPrioritySliderHighlight() {
        ocrPrioritySliderHighlightTask?.cancel()
        ocrPrioritySliderHighlightTask = nil
        isOCRPrioritySliderHighlighted = false
    }

    private func cancelTimelineScrollOrientationHighlight() {
        timelineScrollOrientationHighlightTask?.cancel()
        timelineScrollOrientationHighlightTask = nil
        isTimelineScrollOrientationHighlighted = false
    }

    nonisolated static func searchResults(for query: String) -> [SettingsSearchEntry] {
        guard !query.isEmpty else { return [] }
        let queryWords = query.lowercased().split(separator: " ").map(String.init)

        return searchIndex.filter { entry in
            queryWords.allSatisfy { word in
                entry.searchableText.contains { $0.lowercased().contains(word) }
                    || entry.tab.rawValue.lowercased().contains(word)
                    || entry.cardTitle.lowercased().contains(word)
            }
        }
    }

    private nonisolated static let searchIndex: [SettingsSearchEntry] = [
        SettingsSearchEntry(id: "general.shortcuts", tab: .general, cardTitle: "Keyboard Shortcuts (Global)", cardIcon: "command",
            searchableText: ["keyboard shortcuts", "global keyboard shortcuts", "open timeline", "open dashboard", "toggle recording", "quick comment", "add comment", "comment hotkey", "hotkey", "shortcut"]),
        SettingsSearchEntry(id: "general.updates", tab: .general, cardTitle: "Updates", cardIcon: "arrow.down.circle",
            searchableText: ["updates", "automatic updates", "check for updates", "check now"]),
        SettingsSearchEntry(id: "general.startup", tab: .general, cardTitle: "Startup", cardIcon: "power",
            searchableText: ["startup", "launch at login", "start automatically", "dock icon", "show dock icon", "menu bar icon", "show menu bar"]),
        SettingsSearchEntry(id: "general.appearance", tab: .general, cardTitle: "Appearance", cardIcon: "paintbrush",
            searchableText: ["appearance", "font style", "accent color", "color theme", "timeline colored borders", "scrubbing animation", "scroll sensitivity", "scroll orientation", "horizontal scroll", "vertical scroll", "dark mode", "light mode", "theme"]),
        SettingsSearchEntry(id: "capture.rate", tab: .capture, cardTitle: "Capture Rate", cardIcon: "gauge.with.dots.needle.50percent",
            searchableText: ["capture rate", "capture interval", "capture on window change", "frame rate", "screenshot frequency", "mouse position", "capture mouse", "pointer overlay", "timeline cursor"]),
        SettingsSearchEntry(id: "capture.menuBarIcon", tab: .capture, cardTitle: "Menu Bar Icon", cardIcon: "menubar.rectangle",
            searchableText: ["menu bar icon", "show capture animation", "capture animation", "camera shutter", "screenshot animation", "capture feedback", "menu icon animation", "capture pulse"]),
        SettingsSearchEntry(id: "capture.compression", tab: .capture, cardTitle: "Compression", cardIcon: "archivebox",
            searchableText: ["compression", "video quality", "similar frames deduplication threshold", "deduplication", "duplicate frames", "similar frames", "storage size", "mouse movement dedup", "keep frames on mouse movement"]),
        SettingsSearchEntry(id: "capture.pauseReminder", tab: .capture, cardTitle: "Recording Stopped Reminder", cardIcon: "bell.badge",
            searchableText: ["recording stopped reminder", "pause reminder", "remind me later", "notification", "reminder interval"]),
        SettingsSearchEntry(id: "capture.inPageURLs", tab: .capture, cardTitle: "In-Page URLs (Experimental)", cardIcon: "link.badge.plus",
            searchableText: ["in-page urls", "experimental", "automation", "apple script", "javascript from apple events", "wikipedia test"]),
        SettingsSearchEntry(id: "storage.rewindData", tab: .storage, cardTitle: "Rewind Data", cardIcon: "arrow.counterclockwise",
            searchableText: ["rewind data", "use rewind", "rewind recordings", "import rewind", "rewind cutoff", "rewind cutoff date", "rewind cutoff time"]),
        SettingsSearchEntry(id: "storage.databaseLocations", tab: .storage, cardTitle: "Database Locations", cardIcon: "externaldrive",
            searchableText: ["database locations", "retrace database folder", "rewind database", "choose folder", "storage location", "db path"]),
        SettingsSearchEntry(id: "storage.retentionPolicy", tab: .storage, cardTitle: "Retention Policy", cardIcon: "calendar.badge.clock",
            searchableText: ["retention policy", "keep recordings", "auto delete", "retention days", "data retention", "forever"]),
        SettingsSearchEntry(id: "exportData.comingSoon", tab: .exportData, cardTitle: "Coming Soon", cardIcon: "clock",
            searchableText: ["export", "import", "data export"]),
        SettingsSearchEntry(id: "privacy.excludedApps", tab: .privacy, cardTitle: "App Level Redaction", cardIcon: "app.badge.checkmark",
            searchableText: ["excluded apps", "block app", "privacy", "apps not recorded", "app exclusion"]),
        SettingsSearchEntry(id: "privacy.frameRedaction", tab: .privacy, cardTitle: "Window Level Redaction", cardIcon: "eye.slash",
            searchableText: ["redaction", "window title", "browser url", "black frames", "privacy rules", "incognito", "browsing", "automation", "vivaldi", "sigmaos"]),
        SettingsSearchEntry(id: "privacy.phraseRedaction", tab: .privacy, cardTitle: "Phrase Level Redaction", cardIcon: "text.viewfinder",
            searchableText: ["phrase redaction", "keyword redaction", "redact on keyword", "banned phrases", "sensitive text", "scramble", "ocr redaction", "searchable text", "manual phrases"]),
        SettingsSearchEntry(id: "privacy.quickDelete", tab: .privacy, cardTitle: "Quick Delete", cardIcon: "clock.arrow.circlepath",
            searchableText: ["quick delete", "delete recent", "last 5 minutes", "last hour", "last 24 hours", "erase"]),
        SettingsSearchEntry(id: "privacy.permissions", tab: .privacy, cardTitle: "Permissions", cardIcon: "hand.raised",
            searchableText: ["permissions", "screen recording", "accessibility", "grant permission"]),
        SettingsSearchEntry(id: "power.ocrProcessing", tab: .power, cardTitle: "OCR Processing", cardIcon: "text.viewfinder",
            searchableText: ["ocr processing", "enable ocr", "text extraction", "plugged in", "battery", "ocr"]),
        SettingsSearchEntry(id: "power.powerEfficiency", tab: .power, cardTitle: "Power Efficiency", cardIcon: "leaf.fill",
            searchableText: ["power efficiency", "max ocr rate", "energy", "fan noise", "cpu usage", "fps"]),
        SettingsSearchEntry(id: "power.appFilter", tab: .power, cardTitle: "App Filter", cardIcon: "app.badge",
            searchableText: ["app filter", "skip ocr", "ocr apps", "filter apps", "power saving"]),
        SettingsSearchEntry(id: "tags.manageTags", tab: .tags, cardTitle: "Manage Tags", cardIcon: "tag",
            searchableText: ["manage tags", "create tag", "delete tag", "tag name", "organize"]),
        SettingsSearchEntry(id: "advanced.cache", tab: .advanced, cardTitle: "Cache", cardIcon: "externaldrive",
            searchableText: ["cache", "clear cache", "app name cache", "refresh"]),
        SettingsSearchEntry(id: "advanced.timeline", tab: .advanced, cardTitle: "Timeline", cardIcon: "play.rectangle",
            searchableText: ["timeline", "video controls", "play pause", "auto advance"]),
        SettingsSearchEntry(id: "advanced.developer", tab: .advanced, cardTitle: "Developer", cardIcon: "hammer",
            searchableText: ["developer", "frame ids", "ocr debug overlay", "database schema", "debug"]),
        SettingsSearchEntry(id: "advanced.dangerZone", tab: .advanced, cardTitle: "Danger Zone", cardIcon: "exclamationmark.triangle",
            searchableText: ["danger zone", "reset all settings", "delete all data", "factory reset"]),
    ]
}
