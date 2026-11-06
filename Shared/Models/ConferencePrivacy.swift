import Foundation

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
    /// Status identity for a recognized window, even when call activity is uncertain.
    public let callID: String?
    /// Opaque permission token available only for a verified active call session.
    public let consentSessionID: String?
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
        consentSessionID: String? = nil,
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
        self.consentSessionID = consentSessionID
        self.isPreferredMenuCandidate = isPreferredMenuCandidate
    }
}

