import Foundation

enum TimelineDateSearchSupport {
    static let boundedLoadBoundaryEpsilonSeconds: TimeInterval = 0.001

    enum DateSearchAnchorMode: String {
        case exact
        case firstFrameInMinute
        case firstFrameInHour
        case firstFrameInDay
        case firstFrameInMonth
        case firstFrameInYear
    }

    enum PlayheadRelativeDirection {
        case backward
        case forward
    }

    enum PlayheadRelativeUnit {
        case minute
        case hour
        case day
        case week
        case month
        case year

        init?(token: String) {
            switch token {
            case "minute", "minutes", "min", "mins":
                self = .minute
            case "hour", "hours", "hr", "hrs", "h":
                self = .hour
            case "day", "days", "d":
                self = .day
            case "week", "weeks", "wk", "wks", "w":
                self = .week
            case "month", "months", "mo", "mos":
                self = .month
            case "year", "years", "yr", "yrs", "y":
                self = .year
            default:
                return nil
            }
        }
    }

    struct PlayheadRelativeOffset {
        let amount: Int
        let unit: PlayheadRelativeUnit
        let direction: PlayheadRelativeDirection
    }

    enum RelativeLookbackAnchorEdge {
        case first
        case last
    }

    struct RelativeLookbackRange {
        let start: Date
        let end: Date
        let anchorEdge: RelativeLookbackAnchorEdge
    }
}
