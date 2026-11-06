import XCTest
@testable import Capture

final class ConferenceSessionPrivacyPolicyTests: XCTestCase {
    func testConsentDoesNotSurviveCallDisappearanceAndReappearance() {
        var consent = ConferenceCallConsentState()
        consent.update(activeCallIDs: ["meet-window"])
        XCTAssertTrue(consent.disableFaceBlur(callID: "meet-window"))
        XCTAssertTrue(consent.isBypassed(callID: "meet-window"))

        consent.update(activeCallIDs: [])
        consent.update(activeCallIDs: ["meet-window"])
        XCTAssertFalse(consent.isBypassed(callID: "meet-window"))
    }

    func testConsentOnlyAppliesToTheSelectedActiveCall() {
        var consent = ConferenceCallConsentState()
        consent.update(activeCallIDs: ["meet-window", "zoom-window"])
        XCTAssertFalse(consent.disableFaceBlur(callID: "unknown-call"))
        XCTAssertTrue(consent.disableFaceBlur(callID: "meet-window"))
        XCTAssertFalse(consent.isBypassed(callID: "zoom-window"))
        consent.reset()
        XCTAssertFalse(consent.isBypassed(callID: "meet-window"))
        XCTAssertFalse(consent.disableFaceBlur(callID: "meet-window"))
    }

    func testConsentOverrideRejectsCallsThatHaveNeverBeenObserved() async {
        let capture = CGWindowListCapture()
        let accepted = await capture.disableFaceBlurForConferenceCall(callID: "unknown-call")
        XCTAssertFalse(accepted)
    }

    func testMatchesInstalledZoomBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "us.zoom.xos",
            browserURL: nil,
            windowName: "Weekly sync"
        )

        XCTAssertEqual(match?.kind, .zoom)
        XCTAssertEqual(match?.matchedBy, "bundle_id")
    }

    func testMatchesFaceTimeBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.apple.FaceTime",
            browserURL: nil,
            windowName: "FaceTime"
        )

        XCTAssertEqual(match?.kind, .faceTime)
    }

    func testMatchesDiscordByNativeBundleAndRecordingWindowTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.hnc.Discord",
            browserURL: nil,
            windowName: "Friends - Camera and microphone recording"
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "bundle_id_window_title")
    }

    func testMatchesDiscordByNativeBundleAndSpeakerIndicator() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.hnc.Discord",
            browserURL: nil,
            windowName: "🔊 General"
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "bundle_id_window_title")
    }

    func testMatchesDiscordByBrowserURLAndRecordingWindowTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://discord.com/channels/@me",
            windowName: "• Discord | #help | retrace - Camera and microphone recording - Google Chrome"
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "browser_url_window_title")
    }

    func testMatchesDiscordByBrowserWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "• Discord | #help | retrace - Camera and microphone recording - Google Chrome"
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testIgnoresDiscordBrowserWindowWithoutCallIndicator() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://discord.com/channels/@me",
            windowName: "• Discord | #help | retrace - Google Chrome"
        )

        XCTAssertNil(match)
    }

    func testMatchesDiscordByBrowserURLWhenMediaCaptureIsActiveWithoutCallIndicator() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://discord.com/channels/@me",
            windowName: "• Discord | #help | retrace - Google Chrome",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "browser_url_media_in_use")
    }

    func testMatchesDiscordByWindowTitleWhenMediaCaptureIsActiveAndURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "• Discord | #help | retrace - Google Chrome",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .discord)
        XCTAssertEqual(match?.matchedBy, "window_title_media_in_use")
    }

    func testMatchesSlackHuddleByNativeSlackBundleAndWindowTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            windowName: "Huddle: #auto-revenue - fpt studio - Slack"
        )

        XCTAssertEqual(match?.kind, .slack)
        XCTAssertEqual(match?.matchedBy, "bundle_id_window_title")
    }

    func testIgnoresNonHuddleSlackWindow() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            windowName: "#auto-revenue - fpt studio - Slack"
        )

        XCTAssertNil(match)
    }

    func testMatchesSlackByNativeBundleWhenMediaCaptureIsActiveWithoutHuddleTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tinyspeck.slackmacgap",
            browserURL: nil,
            windowName: "#auto-revenue - fpt studio - Slack",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .slack)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresWeChatWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tencent.xinWeChat",
            browserURL: nil,
            windowName: "WeChat"
        )

        XCTAssertNil(match)
    }

    func testMatchesWeChatByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tencent.xinWeChat",
            browserURL: nil,
            windowName: "WeChat",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .weChat)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresVKMessengerWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.vk.medesktop",
            browserURL: nil,
            windowName: "VK Мессенджер"
        )

        XCTAssertNil(match)
    }

    func testMatchesVKMessengerByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.vk.medesktop",
            browserURL: nil,
            windowName: "VK Мессенджер",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .vkMessenger)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresKakaoTalkWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.kakao.KakaoTalkMac",
            browserURL: nil,
            windowName: "KakaoTalk"
        )

        XCTAssertNil(match)
    }

    func testMatchesKakaoTalkByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.kakao.KakaoTalkMac",
            browserURL: nil,
            windowName: "KakaoTalk",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .kakaoTalk)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresLINEWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "jp.naver.line.mac",
            browserURL: nil,
            windowName: "LINE"
        )

        XCTAssertNil(match)
    }

    func testMatchesLINEByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "jp.naver.line.mac",
            browserURL: nil,
            windowName: "LINE",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .line)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresDingTalkLiteWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.alibaba.DingTalkLite",
            browserURL: nil,
            windowName: "DingTalk"
        )

        XCTAssertNil(match)
    }

    func testMatchesDingTalkLiteByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.alibaba.DingTalkLite",
            browserURL: nil,
            windowName: "DingTalk",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .dingTalk)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresWhatsAppWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "net.whatsapp.WhatsApp",
            browserURL: nil,
            windowName: "WhatsApp"
        )

        XCTAssertNil(match)
    }

    func testMatchesWhatsAppByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "net.whatsapp.WhatsApp",
            browserURL: nil,
            windowName: "WhatsApp",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .whatsapp)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresSignalWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "org.whispersystems.signal-desktop",
            browserURL: nil,
            windowName: "Signal"
        )

        XCTAssertNil(match)
    }

    func testMatchesSignalByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "org.whispersystems.signal-desktop",
            browserURL: nil,
            windowName: "Signal",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .signal)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresTelegramWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tdesktop.Telegram",
            browserURL: nil,
            windowName: "Telegram"
        )

        XCTAssertNil(match)
    }

    func testMatchesTelegramByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tdesktop.Telegram",
            browserURL: nil,
            windowName: "Telegram",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .telegram)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testIgnoresViberWithoutMediaCapture() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.viber.osx",
            browserURL: nil,
            windowName: "Rakuten Viber"
        )

        XCTAssertNil(match)
    }

    func testMatchesViberByNativeBundleWhenMediaCaptureIsActive() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.viber.osx",
            browserURL: nil,
            windowName: "Rakuten Viber",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .viber)
        XCTAssertEqual(match?.matchedBy, "bundle_id_media_in_use")
    }

    func testMatchesNativeGoogleMeetBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.meet",
            browserURL: nil,
            windowName: "Google Meet"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "bundle_id")
    }

    func testMatchesModernTeamsBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.microsoft.teams2",
            browserURL: nil,
            windowName: "Standup"
        )

        XCTAssertEqual(match?.kind, .teams)
    }

    func testMatchesTencentMeetingBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tencent.meeting",
            browserURL: nil,
            windowName: "Tencent Meeting"
        )

        XCTAssertEqual(match?.kind, .tencentMeeting)
        XCTAssertEqual(match?.matchedBy, "bundle_id")
    }

    func testMatchesVooVMeetingBundleID() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.tencent.tencentmeeting",
            browserURL: nil,
            windowName: "VooV Meeting"
        )

        XCTAssertEqual(match?.kind, .voovMeeting)
        XCTAssertEqual(match?.matchedBy, "bundle_id")
    }

    func testMatchesGoogleMeetByBrowserURLHost() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://meet.google.com/abc-defg-hij",
            windowName: "Sprint Review"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "browser_url")
    }

    func testMatchesMessengerByBrowserURLGroupCall() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://messenger.com/groupcall/ROOM:3708447682546510/?call_id=3774997536",
            windowName: "Sohrab Amin"
        )

        XCTAssertEqual(match?.kind, .messenger)
        XCTAssertEqual(match?.matchedBy, "browser_url_groupcall")
    }

    func testMatchesMessengerByWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "Messenger call 📞"
        )

        XCTAssertEqual(match?.kind, .messenger)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testIgnoresMessengerBrowserWindowWithoutCallSignals() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://messenger.com/t/123456",
            windowName: "Messenger"
        )

        XCTAssertNil(match)
    }

    func testMatchesGoogleMeetByWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "company.thebrowser.Browser",
            browserURL: nil,
            windowName: "Design Review - Google Meet"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testMatchesGoogleMeetByMeetingCodeWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "Meet - chc-ujhh-qox"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "window_title_meet_code")
    }

    func testMatchesSlackHuddleByBrowserWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "Huddle: #auto-revenue - fpt studio - Slack"
        )

        XCTAssertEqual(match?.kind, .slack)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testMatchesSlackByBrowserURLWhenMediaCaptureIsActiveWithoutHuddleTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://app.slack.com/client/T123/C456",
            windowName: "#auto-revenue - fpt studio - Slack - Google Chrome",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .slack)
        XCTAssertEqual(match?.matchedBy, "browser_url_media_in_use")
    }

    func testMatchesSlackByWindowTitleWhenMediaCaptureIsActiveAndURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "#auto-revenue - fpt studio - Slack - Google Chrome",
            hasActiveMediaCapture: true
        )

        XCTAssertEqual(match?.kind, .slack)
        XCTAssertEqual(match?.matchedBy, "window_title_media_in_use")
    }

    func testMatchesGoogleMeetChromeAppShimByBrowserURLHost() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome.app.meetpwa123",
            browserURL: "https://meet.google.com/abc-defg-hij",
            windowName: "Google Meet"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "browser_url")
    }

    func testMatchesGoogleMeetChromeAppShimByMeetingCodeWindowTitle() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome.app.meetpwa123",
            browserURL: nil,
            windowName: "Meet - abc-defg-hij"
        )

        XCTAssertEqual(match?.kind, .googleMeet)
        XCTAssertEqual(match?.matchedBy, "window_title_meet_code")
    }

    func testMatchesWebTeamsByBrowserURLHost() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://teams.live.com/v2/meet/meet-now",
            windowName: "Microsoft Teams meeting"
        )

        XCTAssertEqual(match?.kind, .teams)
        XCTAssertEqual(match?.matchedBy, "browser_url")
    }

    func testMatchesWebTeamsByWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "Microsoft Teams meeting"
        )

        XCTAssertEqual(match?.kind, .teams)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testMatchesWebZoomByBrowserURLHost() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://us05web.zoom.us/wc/join/123456789",
            windowName: "Zoom Meeting"
        )

        XCTAssertEqual(match?.kind, .zoom)
        XCTAssertEqual(match?.matchedBy, "browser_url")
    }

    func testMatchesWebZoomByWindowTitleWhenURLUnavailable() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: nil,
            windowName: "Daily Sync | Zoom"
        )

        XCTAssertEqual(match?.kind, .zoom)
        XCTAssertEqual(match?.matchedBy, "window_title")
    }

    func testIgnoresNonConferenceBrowserSession() {
        let match = ConferenceSessionPrivacyPolicy.match(
            appBundleID: "com.google.Chrome",
            browserURL: "https://calendar.google.com",
            windowName: "Google Calendar"
        )

        XCTAssertNil(match)
    }

    func testLikelyConferenceOverlayWindowAcceptsMeetChromeWidget() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowName: "Meet - abc-defg-hij"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsMeetChromeAppShimWidget() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "Google Meet",
            bundleID: "com.google.Chrome.app.meetpwa123",
            windowName: "Meet - abc-defg-hij"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsSlackHuddleWindow() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowName: "Huddle: #auto-revenue - fpt studio - Slack"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsDiscordRecordingWindow() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "Discord",
            bundleID: "com.hnc.Discord",
            windowName: "Friends - Camera and microphone recording"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsTencentMeetingOverlay() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "TencentMeeting",
            bundleID: "com.tencent.meeting",
            windowName: "Tencent Meeting"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsVooVMeetingOverlay() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "VooV Meeting",
            bundleID: "com.tencent.tencentmeeting",
            windowName: "VooV Meeting"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowAcceptsZoomFloatingVideoWindowOnHigherLayer() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 26,
            ownerName: "zoom.us",
            bundleID: "us.zoom.xos",
            windowName: "zoom floating video window"
        )

        XCTAssertTrue(accepted)
    }

    func testLikelyConferenceOverlayWindowRejectsLayerThreeNonConferenceWindow() {
        let accepted = ConferenceSessionPrivacyPolicy.isLikelyConferenceOverlayWindow(
            layer: 3,
            ownerName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowName: "Google Calendar"
        )

        XCTAssertFalse(accepted)
    }

}
