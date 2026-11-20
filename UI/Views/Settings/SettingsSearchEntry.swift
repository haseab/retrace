import Foundation

struct SettingsSearchEntry: Identifiable {
    let id: String
    let tab: SettingsTab
    let cardTitle: String
    let cardIcon: String
    let searchableText: [String]

    var breadcrumb: String { "\(tab.rawValue) > \(cardTitle)" }
}
