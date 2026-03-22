import Foundation
import SQLite3
import Shared

// MARK: - Daily Metrics Queries

/// SQL queries for daily_metrics table
/// Tracks engagement events (timeline opens, searches, text copies) as individual rows
/// Owner: DATABASE agent
public enum DailyMetricsQueries {

    // MARK: - Metric Types

    /// Standard metric type identifiers
    public enum MetricType: String {
        case timelineOpens = "timeline_opens"
        case searches = "searches"
        case textCopies = "text_copies"

        // New metrics for Retrace Wrapped
        case imageCopies = "image_copies"
        case imageSaves = "image_saves"
        case deeplinkCopies = "deeplink_copies"
        case timelineSessionDuration = "timeline_session_duration"  // metadata: duration in ms
        case filteredSearchQuery = "filtered_search_query"  // metadata: JSON {query, filters}
        case timelineFilterQuery = "timeline_filter_query"  // metadata: JSON {bundleID, windowName, browserUrl, startDate, endDate}
        case scrubDistance = "scrub_distance"  // metadata: distance in pixels per session
        case searchDialogOpens = "search_dialog_opens"
        case ocrReprocessRequests = "ocr_reprocess_requests"
        case arrowKeyNavigation = "arrow_key_navigation"  // metadata: "left" or "right"
        case shiftDragZoomRegion = "shift_drag_zoom_region"  // metadata: JSON {region, screenSize}
        case shiftDragTextCopy = "shift_drag_text_copy"  // metadata: copied text
        case stillFrameDragOCR = "still_frame_drag_ocr"  // metadata: JSON {gesture, frameID}
        case appLaunches = "app_launches"
        case launchSurfaceReveal = "launch_surface_reveal"  // metadata: JSON {source, action, appWasHidden, dashboardWasVisible, isInitialized}
        case keyboardShortcut = "keyboard_shortcut"  // metadata: shortcut identifier (e.g. "cmd+c", "cmd+f")
        case dateSearchSubmitted = "date_search_submitted"
        case dateSearchOutcome = "date_search_outcome"

        // Timeline tagging/comments/playback metrics
        case segmentHide = "segment_hide"
        case segmentUnhide = "segment_unhide"
        case tagSubmenuOpen = "tag_submenu_open"
        case tagToggleOnBlock = "tag_toggle_on_block"
        case tagCreateAndAddOnBlock = "tag_create_and_add_on_block"
        case commentSubmenuOpen = "comment_submenu_open"
        case commentAdded = "comment_added"
        case commentDeletedFromBlock = "comment_deleted_from_block"
        case commentAttachmentPickerOpened = "comment_attachment_picker_opened"
        case commentAttachmentOpened = "comment_attachment_opened"
        case allCommentsOpened = "all_comments_opened"
        case playbackToggled = "playback_toggled"
        case playbackSpeedChanged = "playback_speed_changed"

        // Recording/pause/system-monitor/settings metrics
        case recordingStartedFromMenu = "recording_started_from_menu"
        case recordingPauseSelected = "recording_pause_selected"
        case recordingTurnedOff = "recording_turned_off"
        case recordingAutoResumed = "recording_auto_resumed"
        case systemMonitorOpened = "system_monitor_opened"
        case settingsSearchOpened = "settings_search_opened"
        case dockIconVisibilityToggle = "dock_icon_visibility_toggle"  // metadata: JSON {enabled, source}
        case dockMenuAction = "dock_menu_action"  // metadata: JSON {action, source}
        case redactionRulesUpdated = "redaction_rules_updated"
        case privateWindowRedactionToggle = "private_window_redaction_toggle"
        case systemMonitorSettingsOpened = "system_monitor_settings_opened"
        case systemMonitorOpenPowerOCRCard = "system_monitor_open_power_ocr_card"
        case systemMonitorOpenPowerOCRPriority = "system_monitor_open_power_ocr_priority"
        case inPageURLCollectionToggle = "in_page_url_collection_toggle"
        case mousePositionCaptureToggle = "mouse_position_capture_toggle"
        case mouseMovementDeduplicationToggle = "mouse_movement_deduplication_toggle"
        case inPageURLPermissionProbe = "in_page_url_permission_probe"
        case inPageURLVerification = "in_page_url_verification"
        case inPageURLHover = "in_page_url_hover"  // metadata: JSON {url, linkText, nodeID}
        case inPageURLClick = "in_page_url_click"  // metadata: JSON {url, linkText, nodeID}
        case inPageURLRightClick = "in_page_url_right_click"  // metadata: JSON {url, linkText, nodeID}
        case inPageURLCopyLink = "in_page_url_copy_link"  // metadata: JSON {url, linkText, nodeID}
        case browserLinkOpened = "browser_link_opened"
        case feedbackReportExport = "feedback_report_export"  // metadata: JSON {outcome, source, feedbackType, includeLogs, includeScreenshot, exportedFileCount}
        case watchdogCrashBannerAction = "watchdog_crash_banner_action"  // metadata: JSON {action, fileName, reportAgeSeconds}
        case walFailureBannerAction = "wal_failure_banner_action"  // metadata: JSON {action, fileName, reportAgeSeconds}
        case storageHealthBannerAction = "storage_health_banner_action"  // metadata: JSON {action, severity, availableGB, shouldStop}
        case crashRecoveryApprovalBannerAction = "crash_recovery_approval_banner_action"  // metadata: JSON {action, status}
        case debugWatchdogHangTriggered = "debug_watchdog_hang_triggered"
        case debugForcedTerminationTriggered = "debug_forced_termination_triggered"
        case developerSettingToggle = "developer_setting_toggle"  // metadata: JSON {source, settingKey, isEnabled}
        case debugCrashTriggered = "debug_crash_triggered"
        case crashAutoRestart = "crash_auto_restart"  // metadata: JSON {source}
        case rewindCutoffDateUpdated = "rewind_cutoff_date_updated"  // metadata: JSON {cutoffTimestampMs}

        // Delete actions
        case frameDeleted = "frame_deleted"
        case segmentDeleted = "segment_deleted"
    }

    // MARK: - Insert

    /// Record a single metric event
    static func recordEvent(
        db: OpaquePointer,
        metricType: MetricType,
        timestamp: Date = Date(),
        metadata: String? = nil
    ) throws {
        let timestampMs = Int64(timestamp.timeIntervalSince1970 * 1000)

        let sql = """
            INSERT INTO daily_metrics (metricType, timestamp, metadata)
            VALUES (?, ?, ?)
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, timestampMs)

        if let metadata = metadata {
            sqlite3_bind_text(statement, 3, metadata, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 3)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }
    }

    // MARK: - Query

    /// Get daily counts for a metric type within a date range (for 7-day graphs)
    /// Returns array of (date, count) tuples sorted by date ascending, grouped by local timezone
    static func getDailyCounts(
        db: OpaquePointer,
        metricType: MetricType,
        from startDate: Date,
        to endDate: Date
    ) throws -> [(date: Date, value: Int64)] {
        let startTimestamp = startOfDay(startDate)
        let endTimestamp = endOfDay(endDate)

        let sql = """
            SELECT
                date(timestamp / 1000.0, 'unixepoch', 'localtime') as local_day,
                COUNT(*) as count
            FROM daily_metrics
            WHERE metricType = ? AND timestamp >= ? AND timestamp <= ?
            GROUP BY local_day
            ORDER BY local_day ASC
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int64(statement, 3, endTimestamp)

        var results: [(date: Date, value: Int64)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let date = parseLocalDay(sqlite3_column_text(statement, 0)) else {
                continue
            }
            let count = sqlite3_column_int64(statement, 1)
            results.append((date: date, value: count))
        }

        return results
    }

    /// Get total count of a metric for a date range
    static func getTotalCount(
        db: OpaquePointer,
        metricType: MetricType,
        from startDate: Date,
        to endDate: Date
    ) throws -> Int64 {
        let startTimestamp = startOfDay(startDate)
        let endTimestamp = endOfDay(endDate)

        let sql = """
            SELECT COUNT(*)
            FROM daily_metrics
            WHERE metricType = ? AND timestamp >= ? AND timestamp <= ?
            """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(
                query: sql,
                underlying: String(cString: sqlite3_errmsg(db))
            )
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, metricType.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, startTimestamp)
        sqlite3_bind_int64(statement, 3, endTimestamp)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return sqlite3_column_int64(statement, 0)
    }

    // MARK: - Helpers

    /// Get timestamp for start of day (midnight) in milliseconds
    private static func startOfDay(_ date: Date) -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        return Int64(startOfDay.timeIntervalSince1970 * 1000)
    }

    /// Get timestamp for end of day (23:59:59.999) in milliseconds
    private static func endOfDay(_ date: Date) -> Int64 {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!.addingTimeInterval(-0.001)
        return Int64(endOfDay.timeIntervalSince1970 * 1000)
    }

    private static func parseLocalDay(_ localDayText: UnsafePointer<UInt8>?) -> Date? {
        guard let localDayText else { return nil }

        let components = String(cString: localDayText).split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return nil
        }

        var calendar = Calendar.current
        calendar.timeZone = .current

        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
