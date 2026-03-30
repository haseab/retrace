import SwiftUI
import AppKit
import Shared

struct ModernSettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var dangerous: Bool = false
    var trailingAction: (() -> Void)? = nil
    var trailingActionIcon: String? = nil
    var trailingActionTooltip: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.retraceCalloutMedium)
                    .foregroundColor(dangerous ? .retraceDanger : .retraceSecondary)

                Text(title)
                    .font(.retraceBodyBold)
                    .foregroundColor(dangerous ? .retraceDanger : .retracePrimary)

                Spacer()

                if let action = trailingAction, let actionIcon = trailingActionIcon {
                    Button(action: action) {
                        Image(systemName: actionIcon)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(trailingActionTooltip ?? "")
                }
            }

            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dangerous ? Color.retraceDanger.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct ModernToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.retraceCalloutMedium)
                        .foregroundColor(disabled ? .retraceSecondary : .retracePrimary)

                    if let badge = badge {
                        Text(badge)
                            .font(.retraceTinyBold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.retraceAccent.opacity(0.3))
                            .cornerRadius(4)
                    }
                }

                Text(subtitle)
                    .font(.retraceCaption2)
                    .foregroundColor(.retraceSecondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .retraceAccent))
                .scaleEffect(0.85)
                .disabled(disabled)
        }
        .padding(.vertical, 4)
    }
}

struct ModernShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            Text(shortcut)
                .font(.retraceMono)
                .foregroundColor(.retraceSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)
        }
    }
}

struct ModernPermissionRow: View {
    let label: String
    let status: PermissionStatus
    var enableAction: (() -> Void)? = nil
    var openSettingsAction: (() -> Void)? = nil
    @State private var isHoveringGrantedControl = false
    private static let grantedControlWidth: CGFloat = 120

    var body: some View {
        HStack {
            Text(label)
                .font(.retraceCalloutMedium)
                .foregroundColor(.retracePrimary)

            Spacer()

            if status == .granted {
                ZStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.retraceSuccess)
                            .frame(width: 8, height: 8)

                        Text(status.rawValue)
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSuccess)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(width: Self.grantedControlWidth)
                    .background(Color.retraceSuccess.opacity(0.1))
                    .cornerRadius(8)
                    .opacity((openSettingsAction != nil && isHoveringGrantedControl) ? 0 : 1)

                    if let openSettingsAction {
                        Button(action: openSettingsAction) {
                            Text("Change")
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.white)
                                .padding(.vertical, 6)
                                .frame(width: Self.grantedControlWidth)
                                .background(Color.retraceAccent)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .opacity(isHoveringGrantedControl ? 1 : 0)
                        .allowsHitTesting(isHoveringGrantedControl)
                    }
                }
                .onHover { hovering in
                    guard openSettingsAction != nil else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringGrantedControl = hovering
                    }
                }
            } else {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.retraceWarning)
                            .frame(width: 8, height: 8)

                        Text("Not Enabled")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceWarning)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.retraceWarning.opacity(0.1))
                    .cornerRadius(8)

                    if let action = enableAction {
                        Button(action: action) {
                            Text("Enable")
                                .font(.retraceCaption2Bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.retraceAccent)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    if let settingsAction = openSettingsAction {
                        Button(action: settingsAction) {
                            Image(systemName: "gear")
                                .font(.retraceCaption2Medium)
                                .foregroundColor(.retraceSecondary)
                                .padding(6)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("Open System Settings")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ModernSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = geometry.size.width
            let thumbPosition = trackWidth * progress

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient.retraceAccentGradient)
                    .frame(width: max(0, thumbPosition), height: 6)

                Circle()
                    .fill(Color.retraceAccent)
                    .frame(width: isDragging ? 16 : 14, height: isDragging ? 16 : 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    )
                    .shadow(color: Color.retraceAccent.opacity(0.5), radius: isDragging ? 6 : 4)
                    .offset(x: max(0, min(thumbPosition - 7, trackWidth - 14)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { gestureValue in
                        let percentage = max(0, min(1, gestureValue.location.x / trackWidth))
                        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * Double(percentage)
                        let steppedValue = round(rawValue / step) * step
                        let clampedValue = max(range.lowerBound, min(range.upperBound, steppedValue))
                        if clampedValue != value {
                            value = clampedValue
                        }
                    }
            )
        }
        .frame(height: 20)
    }

    private var progress: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}

struct ModernSegmentedPicker<T: Hashable, Content: View>: View {
    @Binding var selection: T
    let options: [T]
    @ViewBuilder let label: (T) -> Content

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                Button(action: { selection = option }) {
                    label(option)
                        .font(selection == option ? .retraceCaptionBold : .retraceCaptionMedium)
                        .foregroundColor(selection == option ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == option ? Color.white.opacity(0.1) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct ModernDropdown: View {
    @Binding var selection: Int
    let options: [(Int, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(action: { selection = option.0 }) {
                    if selection == option.0 {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retracePrimary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.retraceCaption2Medium)
                    .foregroundColor(.retraceSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.05))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
    }
}

struct ModernButton: View {
    let title: String
    let icon: String?
    let style: ButtonStyleType
    let action: () -> Void

    enum ButtonStyleType {
        case primary, secondary, danger
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.retraceCaptionMedium)
                }
                Text(title)
                    .font(.retraceCaptionMedium)
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .retracePrimary
        case .danger: return .retraceDanger
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return .retraceAccent
        case .secondary: return Color.white.opacity(0.05)
        case .danger: return Color.retraceDanger.opacity(0.1)
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary: return Color.clear
        case .secondary: return Color.white.opacity(0.08)
        case .danger: return Color.retraceDanger.opacity(0.3)
        }
    }
}

struct FontStylePicker: View {
    @Binding var selection: RetraceFontStyle

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RetraceFontStyle.allCases) { style in
                Button(action: {
                    selection = style
                }) {
                    VStack(spacing: 8) {
                        Text("Aa")
                            .font(.system(size: 24, weight: .semibold, design: style.design))
                            .foregroundColor(selection == style ? .retracePrimary : .retraceSecondary)

                        VStack(spacing: 2) {
                            Text(style.displayName)
                                .font(.system(size: 11, weight: .semibold, design: style.design))
                                .foregroundColor(selection == style ? .retracePrimary : .retraceSecondary)

                            Text(style.description)
                                .font(.system(size: 10, weight: .regular, design: style.design))
                                .foregroundColor(.retraceSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(selection == style ? Color.white.opacity(0.08) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selection == style ? Color.retraceAccent.opacity(0.5) : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }
}

struct ColorThemePicker: View {
    @Binding var selection: MilestoneCelebrationManager.ColorTheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MilestoneCelebrationManager.ColorTheme.allCases) { theme in
                themeOptionButton(for: theme)
            }
        }
        .padding(6)
        .background(Color.white.opacity(0.03))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func themeOptionButton(for theme: MilestoneCelebrationManager.ColorTheme) -> some View {
        let isSelected = selection == theme

        Button(action: {
            selection = theme
        }) {
            VStack(spacing: 8) {
                Circle()
                    .fill(theme.glowColor)
                    .frame(width: 32, height: 32)

                Text(theme.displayName)
                    .font(.retraceCaptionBold)
                    .foregroundColor(isSelected ? .retracePrimary : .retraceSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? theme.glowColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CaptureIntervalPicker: View {
    @Binding var selectedInterval: Double
    static let intervals: [Double] = [2, 5, 10, 15, 30, 60, 0]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.intervals, id: \.self) { interval in
                Text(Self.intervalLabel(interval))
                    .font(selectedInterval == interval ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedInterval == interval ? .retracePrimary : .retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedInterval == interval ? Color.white.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedInterval = interval
                    }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }

    static func intervalLabel(_ interval: Double) -> String {
        if interval <= 0 {
            return "None"
        }
        if interval >= 60 {
            return "\(Int(interval / 60))m"
        }
        return "\(Int(interval))s"
    }
}

struct PauseReminderDelayPicker: View {
    @Binding var selectedMinutes: Double

    private let options: [(minutes: Double, label: String)] = [
        (1, "1m"), (5, "5m"), (15, "15m"), (30, "30m"), (60, "1h"),
        (120, "2h"), (240, "4h"), (480, "8h"), (0, "Never"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.minutes) { option in
                Text(option.label)
                    .font(selectedMinutes == option.minutes ? .retraceCalloutBold : .retraceCalloutMedium)
                    .foregroundColor(selectedMinutes == option.minutes ? .retracePrimary : .retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedMinutes == option.minutes ? Color.white.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedMinutes = option.minutes
                    }
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }
}

struct RetentionPolicyPicker: View {
    var displayDays: Int
    var onPreviewChange: (Int) -> Void
    var onSelectionEnd: (Int) -> Void

    private let options: [(days: Int, label: String)] = [
        (3, "3D"), (7, "1W"), (14, "2W"), (30, "1M"),
        (60, "2M"), (90, "3M"), (180, "6M"), (365, "1Y"), (0, "Forever")
    ]

    private var sliderIndex: Double {
        Double(options.firstIndex(where: { $0.days == displayDays }) ?? (options.count - 1))
    }

    @State private var lastSelectedDays: Int?

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let horizontalInset: CGFloat = totalWidth / CGFloat(options.count) / 2
                let trackWidth = totalWidth - (horizontalInset * 2)
                let segmentWidth = trackWidth / CGFloat(options.count - 1)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: trackWidth, height: 4)
                        .offset(x: horizontalInset)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient.retraceAccentGradient)
                        .frame(width: max(0, CGFloat(sliderIndex) * segmentWidth), height: 4)
                        .offset(x: horizontalInset)

                    HStack(spacing: 0) {
                        ForEach(0..<options.count, id: \.self) { index in
                            Circle()
                                .fill(index <= Int(sliderIndex) ? Color.retraceAccent : Color.white.opacity(0.3))
                                .frame(width: index == Int(sliderIndex) ? 14 : 8, height: index == Int(sliderIndex) ? 14 : 8)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.2), lineWidth: index == Int(sliderIndex) ? 2 : 0)
                                )
                                .shadow(color: index == Int(sliderIndex) ? Color.retraceAccent.opacity(0.5) : .clear, radius: 4)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let adjustedX = value.location.x - horizontalInset
                            let index = Int(round(adjustedX / segmentWidth))
                            let clampedIndex = max(0, min(options.count - 1, index))
                            let newDays = options[clampedIndex].days
                            if newDays != displayDays {
                                lastSelectedDays = newDays
                                onPreviewChange(newDays)
                            }
                        }
                        .onEnded { _ in
                            if let selectedDays = lastSelectedDays {
                                onSelectionEnd(selectedDays)
                                lastSelectedDays = nil
                            }
                        }
                )
            }
            .frame(height: 30)

            HStack(spacing: 0) {
                ForEach(0..<options.count, id: \.self) { index in
                    Text(options[index].label)
                        .font(index == Int(sliderIndex) ? .retraceTinyBold : .retraceTiny)
                        .foregroundColor(index == Int(sliderIndex) ? .retracePrimary : .retraceSecondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
