import CoreGraphics
import Foundation
import Shared

public enum ConferenceSessionKind: String, Sendable, Equatable {
    case discord = "discord"
    case slack = "slack"
    case messenger = "messenger"
    case weChat = "wechat"
    case vkMessenger = "vk_messenger"
    case kakaoTalk = "kakaotalk"
    case line = "line"
    case dingTalk = "dingtalk"
    case whatsapp = "whatsapp"
    case signal = "signal"
    case telegram = "telegram"
    case viber = "viber"
    case tencentMeeting = "tencent_meeting"
    case voovMeeting = "voov_meeting"
    case zoom = "zoom"
    case faceTime = "facetime"
    case teams = "teams"
    case googleMeet = "google_meet"

    public var displayName: String {
        switch self {
        case .discord:
            return "Discord"
        case .slack:
            return "Slack"
        case .messenger:
            return "Messenger"
        case .weChat:
            return "WeChat"
        case .vkMessenger:
            return "VK Messenger"
        case .kakaoTalk:
            return "KakaoTalk"
        case .line:
            return "LINE"
        case .dingTalk:
            return "DingTalk"
        case .whatsapp:
            return "WhatsApp"
        case .signal:
            return "Signal"
        case .telegram:
            return "Telegram"
        case .viber:
            return "Viber"
        case .tencentMeeting:
            return "Tencent Meeting"
        case .voovMeeting:
            return "VooV Meeting"
        case .zoom:
            return "Zoom"
        case .faceTime:
            return "FaceTime"
        case .teams:
            return "Teams"
        case .googleMeet:
            return "Google Meet"
        }
    }
}

struct ConferenceSessionMatch: Sendable, Equatable {
    let kind: ConferenceSessionKind
    let matchedBy: String
}

public enum ConferenceFramePrivacyOutcome: String, Sendable, Equatable {
    case blurred
    case noFacesDetected = "no_faces_detected"
    case droppedDetectionFailure = "dropped_detection_failure"
    case consentBypassed = "consent_bypassed"
}

public struct ConferenceFramePrivacyEvent: Sendable, Equatable {
    public let timestamp: Date
    public let conferenceKind: ConferenceSessionKind
    public let outcome: ConferenceFramePrivacyOutcome
    public let appBundleID: String?
    public let faceCount: Int
    public let windowLayer: Int?
    public let windowName: String?
    public let browserURL: String?
    public let matchedBy: String?
    public let callID: String?
    public let isPreferredMenuCandidate: Bool

    public init(
        timestamp: Date,
        conferenceKind: ConferenceSessionKind,
        outcome: ConferenceFramePrivacyOutcome,
        appBundleID: String?,
        faceCount: Int,
        windowLayer: Int? = nil,
        windowName: String? = nil,
        browserURL: String? = nil,
        matchedBy: String? = nil,
        callID: String? = nil,
        isPreferredMenuCandidate: Bool = false
    ) {
        self.timestamp = timestamp
        self.conferenceKind = conferenceKind
        self.outcome = outcome
        self.appBundleID = appBundleID
        self.faceCount = faceCount
        self.windowLayer = windowLayer
        self.windowName = windowName
        self.browserURL = browserURL
        self.matchedBy = matchedBy
        self.callID = callID
        self.isPreferredMenuCandidate = isPreferredMenuCandidate
    }
}

enum ConferenceSessionPrivacyPolicy {
    private struct NativeConferenceAppRule: Sendable {
        let kind: ConferenceSessionKind
        let bundleIDs: Set<String>
        let matchedBy: String
    }

    private struct BrowserConferenceHostRule: Sendable {
        let kind: ConferenceSessionKind
        let exactHosts: Set<String>
        let suffixHosts: [String]
        let requiredURLSubstring: String?
        let matchedBy: String
    }

    private struct TitleConferenceRule: Sendable {
        let kind: ConferenceSessionKind
        let markers: [String]
        let matchedBy: String
    }

    static let discordBundleIDs: Set<String> = [
        "com.hnc.discord",
        "com.hnc.discordcanary",
        "com.hnc.discordptb"
    ]

    static let slackBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.slack.slack"
    ]

    static let weChatBundleIDs: Set<String> = [
        "com.tencent.xinwechat"
    ]

    static let vkMessengerBundleIDs: Set<String> = [
        "com.vk.medesktop"
    ]

    static let kakaoTalkBundleIDs: Set<String> = [
        "com.kakao.kakaotalkmac"
    ]

    static let lineBundleIDs: Set<String> = [
        "jp.naver.line.mac"
    ]

    static let dingTalkBundleIDs: Set<String> = [
        "com.alibaba.dingtalklite"
    ]

    static let whatsappBundleIDs: Set<String> = [
        "net.whatsapp.whatsapp"
    ]

    static let signalBundleIDs: Set<String> = [
        "org.whispersystems.signal-desktop"
    ]

    static let telegramBundleIDs: Set<String> = [
        "com.tdesktop.telegram"
    ]

    static let viberBundleIDs: Set<String> = [
        "com.viber.osx"
    ]

    static let tencentMeetingBundleIDs: Set<String> = [
        "com.tencent.meeting"
    ]

    static let voovMeetingBundleIDs: Set<String> = [
        "com.tencent.tencentmeeting"
    ]

    static let googleMeetBundleIDs: Set<String> = [
        "com.google.meet"
    ]

    static let zoomBundleIDs: Set<String> = [
        "us.zoom.xos"
    ]

    static let faceTimeBundleIDs: Set<String> = [
        "com.apple.facetime"
    ]

    static let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2"
    ]

    private static let alwaysOnNativeConferenceRules: [NativeConferenceAppRule] = [
        NativeConferenceAppRule(
            kind: .zoom,
            bundleIDs: zoomBundleIDs,
            matchedBy: "bundle_id"
        ),
        NativeConferenceAppRule(
            kind: .faceTime,
            bundleIDs: faceTimeBundleIDs,
            matchedBy: "bundle_id"
        ),
        NativeConferenceAppRule(
            kind: .googleMeet,
            bundleIDs: googleMeetBundleIDs,
            matchedBy: "bundle_id"
        ),
        NativeConferenceAppRule(
            kind: .teams,
            bundleIDs: teamsBundleIDs,
            matchedBy: "bundle_id"
        ),
        NativeConferenceAppRule(
            kind: .tencentMeeting,
            bundleIDs: tencentMeetingBundleIDs,
            matchedBy: "bundle_id"
        ),
        NativeConferenceAppRule(
            kind: .voovMeeting,
            bundleIDs: voovMeetingBundleIDs,
            matchedBy: "bundle_id"
        )
    ]

    private static let mediaUsageNativeConferenceRules: [NativeConferenceAppRule] = [
        NativeConferenceAppRule(
            kind: .slack,
            bundleIDs: slackBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .weChat,
            bundleIDs: weChatBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .vkMessenger,
            bundleIDs: vkMessengerBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .kakaoTalk,
            bundleIDs: kakaoTalkBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .line,
            bundleIDs: lineBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .dingTalk,
            bundleIDs: dingTalkBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .whatsapp,
            bundleIDs: whatsappBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .signal,
            bundleIDs: signalBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .telegram,
            bundleIDs: telegramBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        ),
        NativeConferenceAppRule(
            kind: .viber,
            bundleIDs: viberBundleIDs,
            matchedBy: "bundle_id_media_in_use"
        )
    ]

    private static let browserBundleIDs: Set<String> = Set(
        AppInfo.browserBundleIDs.map { $0.lowercased() }
    )
    private static let chromiumAppShimBundleIDPrefixes: [String] =
        AppInfo.chromiumHostBrowserBundleIDPrefixes.map { "\($0.lowercased()).app." }

    private static let googleMeetHosts: Set<String> = [
        "meet.google.com"
    ]
    private static let discordHosts: Set<String> = [
        "discord.com",
        "canary.discord.com",
        "ptb.discord.com"
    ]
    private static let discordHostSuffixes: [String] = [
        ".discord.com"
    ]
    private static let messengerHosts: Set<String> = [
        "messenger.com",
        "www.messenger.com"
    ]
    private static let teamsHosts: Set<String> = [
        "teams.live.com",
        "teams.microsoft.com"
    ]
    private static let teamsHostSuffixes: [String] = [
        ".teams.microsoft.com"
    ]
    private static let zoomHosts: Set<String> = [
        "zoom.us",
        "app.zoom.us"
    ]
    private static let zoomHostSuffixes: [String] = [
        ".zoom.us"
    ]

    private static let browserConferenceHostRules: [BrowserConferenceHostRule] = [
        BrowserConferenceHostRule(
            kind: .googleMeet,
            exactHosts: googleMeetHosts,
            suffixHosts: [],
            requiredURLSubstring: nil,
            matchedBy: "browser_url"
        ),
        BrowserConferenceHostRule(
            kind: .messenger,
            exactHosts: messengerHosts,
            suffixHosts: [],
            requiredURLSubstring: "groupcall",
            matchedBy: "browser_url_groupcall"
        ),
        BrowserConferenceHostRule(
            kind: .teams,
            exactHosts: teamsHosts,
            suffixHosts: teamsHostSuffixes,
            requiredURLSubstring: nil,
            matchedBy: "browser_url"
        ),
        BrowserConferenceHostRule(
            kind: .zoom,
            exactHosts: zoomHosts,
            suffixHosts: zoomHostSuffixes,
            requiredURLSubstring: nil,
            matchedBy: "browser_url"
        )
    ]

    private static let googleMeetTitleMarkers: [String] = [
        "google meet",
        "meet.google.com"
    ]
    private static let teamsTitleMarkers: [String] = [
        "microsoft teams",
        "teams meeting"
    ]
    private static let messengerTitleMarkers: [String] = [
        "messenger call"
    ]
    private static let zoomTitleMarkers: [String] = [
        "zoom meeting",
        "meeting | zoom",
        "zoom workplace",
        "| zoom"
    ]
    private static let googleMeetTitleRules: [TitleConferenceRule] = [
        TitleConferenceRule(
            kind: .googleMeet,
            markers: googleMeetTitleMarkers,
            matchedBy: "window_title"
        )
    ]
    private static let heuristicTitleConferenceRules: [TitleConferenceRule] = [
        TitleConferenceRule(
            kind: .teams,
            markers: teamsTitleMarkers,
            matchedBy: "window_title"
        ),
        TitleConferenceRule(
            kind: .messenger,
            markers: messengerTitleMarkers,
            matchedBy: "window_title"
        ),
        TitleConferenceRule(
            kind: .zoom,
            markers: zoomTitleMarkers,
            matchedBy: "window_title"
        )
    ]
    private static let mediaUsageBrowserConferenceRules: [BrowserConferenceHostRule] = [
        BrowserConferenceHostRule(
            kind: .discord,
            exactHosts: discordHosts,
            suffixHosts: discordHostSuffixes,
            requiredURLSubstring: nil,
            matchedBy: "browser_url_media_in_use"
        ),
        BrowserConferenceHostRule(
            kind: .slack,
            exactHosts: ["app.slack.com", "slack.com"],
            suffixHosts: [".slack.com"],
            requiredURLSubstring: nil,
            matchedBy: "browser_url_media_in_use"
        )
    ]
    private static let mediaUsageWindowTitleRules: [TitleConferenceRule] = [
        TitleConferenceRule(
            kind: .discord,
            markers: ["discord"],
            matchedBy: "window_title_media_in_use"
        ),
        TitleConferenceRule(
            kind: .slack,
            markers: ["slack"],
            matchedBy: "window_title_media_in_use"
        )
    ]
    private static let activeMediaWindowTitleMarkers: [String] = [
        "camera and microphone recording",
        "microphone recording",
        "camera recording"
    ]
    private static let overlayWindowTitleMarkers: [String] = [
        "huddle",
        "meet",
        "messenger call",
        "tencent meeting",
        "voov meeting",
        "zoom",
        "teams",
        "facetime"
    ]
    private static let overlayOwnerMarkers: [String] = [
        "discord",
        "slack",
        "chrome",
        "zoom",
        "teams",
        "facetime",
        "tencentmeeting",
        "tencent meeting",
        "voov",
        "voov meeting",
        "safari",
        "edge",
        "brave",
        "arc"
    ]

    static func match(
        appBundleID: String?,
        browserURL: String?,
        windowName: String?,
        hasActiveMediaCapture: Bool = false
    ) -> ConferenceSessionMatch? {
        guard let normalizedBundleID = normalized(appBundleID) else {
            return matchBrowserConference(
                browserURL: browserURL,
                windowName: windowName,
                allowTitleHeuristics: false,
                hasActiveMediaCapture: hasActiveMediaCapture
            )
        }

        if let alwaysOnNativeMatch = nativeConferenceAppMatch(
            normalizedBundleID: normalizedBundleID,
            rules: alwaysOnNativeConferenceRules
        ) {
            return alwaysOnNativeMatch
        }

        if isDiscordBundleID(normalizedBundleID),
           let normalizedWindowName = normalized(windowName),
           looksLikeDiscordConferenceWindowTitle(
               normalizedWindowName,
               requiresAppMarker: false
           ) {
            return ConferenceSessionMatch(kind: .discord, matchedBy: "bundle_id_window_title")
        }

        if slackBundleIDs.contains(normalizedBundleID),
           let normalizedWindowName = normalized(windowName),
           looksLikeSlackHuddleWindowTitle(
               normalizedWindowName,
               requiresAppMarker: false
           ) {
            return ConferenceSessionMatch(kind: .slack, matchedBy: "bundle_id_window_title")
        }

        if hasActiveMediaCapture,
           let mediaUsageMatch = mediaUsageNativeAppConferenceMatch(
               normalizedBundleID: normalizedBundleID
           ) {
            return mediaUsageMatch
        }

        guard isBrowserLikeBundleID(normalizedBundleID) else {
            return nil
        }

        return matchBrowserConference(
            browserURL: browserURL,
            windowName: windowName,
            allowTitleHeuristics: true,
            hasActiveMediaCapture: hasActiveMediaCapture
        )
    }

    private static func matchBrowserConference(
        browserURL: String?,
        windowName: String?,
        allowTitleHeuristics: Bool,
        hasActiveMediaCapture: Bool
    ) -> ConferenceSessionMatch? {
        let normalizedWindowName = normalized(windowName)
        let normalizedBrowserURL = normalized(browserURL)

        if let host = normalizedHost(from: browserURL) {
            if let browserHostMatch = browserConferenceHostMatch(
                host: host,
                normalizedBrowserURL: normalizedBrowserURL,
                rules: browserConferenceHostRules
            ) {
                return browserHostMatch
            }

            if hostMatches(host, exactHosts: discordHosts, suffixHosts: discordHostSuffixes),
               let normalizedWindowName,
               looksLikeDiscordConferenceWindowTitle(
                   normalizedWindowName,
                   requiresAppMarker: false
               ) {
                return ConferenceSessionMatch(
                    kind: .discord,
                    matchedBy: "browser_url_window_title"
                )
            }

            if hasActiveMediaCapture,
               let mediaUsageMatch = mediaUsageBrowserConferenceMatch(host: host) {
                return mediaUsageMatch
            }
        }

        guard let normalizedWindowName else {
            return nil
        }

        if let googleMeetTitleMatch = titleConferenceMatch(
            normalizedWindowName: normalizedWindowName,
            rules: googleMeetTitleRules
        ) {
            return googleMeetTitleMatch
        }

        if allowTitleHeuristics,
           looksLikeMeetCodeWindowTitle(normalizedWindowName) {
            return ConferenceSessionMatch(
                kind: .googleMeet,
                matchedBy: "window_title_meet_code"
            )
        }

        if allowTitleHeuristics,
           let heuristicTitleMatch = titleConferenceMatch(
               normalizedWindowName: normalizedWindowName,
               rules: heuristicTitleConferenceRules
           ) {
            return heuristicTitleMatch
        }

        if allowTitleHeuristics,
           looksLikeDiscordConferenceWindowTitle(
               normalizedWindowName,
               requiresAppMarker: true
           ) {
            return ConferenceSessionMatch(kind: .discord, matchedBy: "window_title")
        }

        if allowTitleHeuristics,
           looksLikeSlackHuddleWindowTitle(
               normalizedWindowName,
               requiresAppMarker: true
           ) {
            return ConferenceSessionMatch(kind: .slack, matchedBy: "window_title")
        }

        if hasActiveMediaCapture,
           let mediaUsageMatch = mediaUsageWindowTitleConferenceMatch(
               normalizedWindowName: normalizedWindowName
           ) {
            return mediaUsageMatch
        }

        return nil
    }

    private static func mediaUsageNativeAppConferenceMatch(
        normalizedBundleID: String
    ) -> ConferenceSessionMatch? {
        if isDiscordBundleID(normalizedBundleID) {
            return ConferenceSessionMatch(kind: .discord, matchedBy: "bundle_id_media_in_use")
        }

        return nativeConferenceAppMatch(
            normalizedBundleID: normalizedBundleID,
            rules: mediaUsageNativeConferenceRules
        )
    }

    private static func mediaUsageBrowserConferenceMatch(host: String) -> ConferenceSessionMatch? {
        return browserConferenceHostMatch(
            host: host,
            normalizedBrowserURL: nil,
            rules: mediaUsageBrowserConferenceRules
        )
    }

    private static func mediaUsageWindowTitleConferenceMatch(
        normalizedWindowName: String
    ) -> ConferenceSessionMatch? {
        return titleConferenceMatch(
            normalizedWindowName: normalizedWindowName,
            rules: mediaUsageWindowTitleRules
        )
    }

    private static func nativeConferenceAppMatch(
        normalizedBundleID: String,
        rules: [NativeConferenceAppRule]
    ) -> ConferenceSessionMatch? {
        guard let rule = rules.first(where: { $0.bundleIDs.contains(normalizedBundleID) }) else {
            return nil
        }

        return ConferenceSessionMatch(kind: rule.kind, matchedBy: rule.matchedBy)
    }

    private static func browserConferenceHostMatch(
        host: String,
        normalizedBrowserURL: String?,
        rules: [BrowserConferenceHostRule]
    ) -> ConferenceSessionMatch? {
        for rule in rules where hostMatches(host, exactHosts: rule.exactHosts, suffixHosts: rule.suffixHosts) {
            if let requiredURLSubstring = rule.requiredURLSubstring,
               normalizedBrowserURL?.contains(requiredURLSubstring) != true {
                continue
            }

            return ConferenceSessionMatch(kind: rule.kind, matchedBy: rule.matchedBy)
        }

        return nil
    }

    private static func titleConferenceMatch(
        normalizedWindowName: String,
        rules: [TitleConferenceRule]
    ) -> ConferenceSessionMatch? {
        guard let rule = rules.first(where: { rule in
            rule.markers.contains(where: normalizedWindowName.contains)
        }) else {
            return nil
        }

        return ConferenceSessionMatch(kind: rule.kind, matchedBy: rule.matchedBy)
    }

    private static func hostMatches(
        _ host: String,
        exactHosts: Set<String>,
        suffixHosts: [String]
    ) -> Bool {
        if exactHosts.contains(host) {
            return true
        }

        return suffixHosts.contains(where: host.hasSuffix)
    }

    private static func isBrowserLikeBundleID(_ bundleID: String) -> Bool {
        if browserBundleIDs.contains(bundleID) {
            return true
        }

        return chromiumAppShimBundleIDPrefixes.contains(where: bundleID.hasPrefix)
    }

    private static func isDiscordBundleID(_ bundleID: String) -> Bool {
        if discordBundleIDs.contains(bundleID) {
            return true
        }

        return bundleID.contains("discord")
    }

    private static func isKnownNativeConferenceBundleID(_ bundleID: String) -> Bool {
        nativeConferenceAppMatch(
            normalizedBundleID: bundleID,
            rules: alwaysOnNativeConferenceRules
        ) != nil ||
            nativeConferenceAppMatch(
                normalizedBundleID: bundleID,
                rules: mediaUsageNativeConferenceRules
            ) != nil
    }

    private static func looksLikeMeetCodeWindowTitle(_ normalizedWindowName: String) -> Bool {
        guard normalizedWindowName.hasPrefix("meet - ") else {
            return false
        }

        let suffix = String(normalizedWindowName.dropFirst("meet - ".count))
        let parts = suffix.split(separator: "-")
        guard parts.count == 3 else {
            return false
        }

        let expectedLengths = [3, 4, 3]
        for (index, part) in parts.enumerated() {
            guard part.count == expectedLengths[index] else {
                return false
            }
            guard part.allSatisfy({ $0.isLowercase && $0.isLetter }) else {
                return false
            }
        }

        return true
    }

    private static func looksLikeSlackHuddleWindowTitle(
        _ normalizedWindowName: String,
        requiresAppMarker: Bool
    ) -> Bool {
        let mentionsSlack = normalizedWindowName.contains("slack")
        guard !requiresAppMarker || mentionsSlack else {
            return false
        }

        return normalizedWindowName.hasPrefix("huddle:")
    }

    private static func looksLikeDiscordConferenceWindowTitle(
        _ normalizedWindowName: String,
        requiresAppMarker: Bool
    ) -> Bool {
        let mentionsDiscord = normalizedWindowName.contains("discord")
        guard !requiresAppMarker || mentionsDiscord else {
            return false
        }

        return hasLiveMediaIndicator(normalizedWindowName)
    }

    private static func hasLiveMediaIndicator(_ normalizedWindowName: String) -> Bool {
        if normalizedWindowName.contains("🔊") {
            return true
        }

        return activeMediaWindowTitleMarkers.contains(where: { normalizedWindowName.contains($0) })
    }

    private static func normalizedHost(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if let components = URLComponents(string: value),
           let host = components.host {
            return host.lowercased()
        }

        if let components = URLComponents(string: "https://\(value)"),
           let host = components.host {
            return host.lowercased()
        }

        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    static func isLikelyConferenceOverlayWindow(
        layer: Int,
        ownerName: String?,
        bundleID: String?,
        windowName: String?
    ) -> Bool {
        guard layer != 0 else {
            return false
        }

        guard let normalizedWindowName = normalized(windowName),
              overlayWindowTitleMarkers.contains(where: { normalizedWindowName.contains($0) }) ||
                looksLikeSlackHuddleWindowTitle(
                    normalizedWindowName,
                    requiresAppMarker: false
                ) ||
                looksLikeDiscordConferenceWindowTitle(
                    normalizedWindowName,
                    requiresAppMarker: false
                ) else {
            return false
        }

        let normalizedOwnerName = normalized(ownerName)
        let normalizedBundleID = normalized(bundleID)
        let ownerOrBundleQualifies =
            (normalizedOwnerName.map { owner in
                overlayOwnerMarkers.contains(where: owner.contains)
            } ?? false) ||
            (normalizedBundleID.map { bundleID in
                isBrowserLikeBundleID(bundleID) ||
                isDiscordBundleID(bundleID) ||
                isKnownNativeConferenceBundleID(bundleID)
            } ?? false)
        guard ownerOrBundleQualifies else {
            return false
        }

        return true
    }
}
