import SwiftUI
import AppKit

struct FloatingDateSearchPanel: View {
    private enum KeyboardSelection {
        case input
        case calendar
    }

    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var enableFrameIDSearch: Bool = false
    @ObservedObject var viewModel: SimpleTimelineViewModel

    @State private var isHovering = false
    @State private var isCalendarButtonHovering = false
    @State private var isSubmitButtonHovering = false
    @State private var keyboardSelection: KeyboardSelection = .input
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private var placeholderText: String {
        "e.g. 8 min ago, next Friday, or yesterday 2pm"
    }

    private var isCalendarKeyboardSelected: Bool {
        keyboardSelection == .calendar
    }

    private var calendarButtonForegroundColor: Color {
        .white.opacity(isCalendarButtonHovering ? 1 : 0.9)
    }

    private var calendarButtonBackgroundColor: Color {
        isCalendarButtonHovering
            ? RetraceMenuStyle.actionBlue
            : Color.white.opacity(0.08)
    }

    private var calendarButtonBorderColor: Color {
        if isCalendarButtonHovering {
            return RetraceMenuStyle.actionBlue.opacity(0.55)
        }
        if isCalendarKeyboardSelected {
            return Color.white.opacity(0.95)
        }
        return Color.white.opacity(0.08)
    }

    private func openCalendarPicker() {
        viewModel.focusCalendarDateGrid()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            viewModel.isCalendarPickerVisible = true
        }
        Task {
            await viewModel.loadDatesWithFrames()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.retraceTinyBold)
                    .foregroundColor(.white.opacity(0.25))
                    .padding(.trailing, 4)

                Text("Jump to")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.retraceTinyBold)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        panelPosition.width += value.translation.width
                        panelPosition.height += value.translation.height
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() }
                else { NSCursor.pop() }
            }

            HStack(spacing: 14) {
                DateSearchField(
                    text: $text,
                    onSubmit: onSubmit,
                    onCancel: onCancel,
                    isCalendarSelected: { isCalendarKeyboardSelected },
                    onMoveToCalendar: {
                        withAnimation(.easeOut(duration: 0.12)) {
                            keyboardSelection = .calendar
                        }
                    },
                    onMoveToInput: {
                        withAnimation(.easeOut(duration: 0.12)) {
                            keyboardSelection = .input
                        }
                    },
                    onCalendarSubmit: {
                        openCalendarPicker()
                    },
                    onInputClicked: {
                        keyboardSelection = .input
                    },
                    placeholder: placeholderText
                )
                .frame(height: 28)

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.retraceHeadline)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                Button(action: onSubmit) {
                    ZStack {
                        Circle()
                            .fill(text.isEmpty ? Color.white.opacity(0.2) : Color.retraceSubmitAccent.opacity(isSubmitButtonHovering ? 1.0 : 0.8))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
                .onHover { hovering in
                    isSubmitButtonHovering = hovering
                    if hovering && !text.isEmpty { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }
            .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
            .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                    .fill(RetraceMenuStyle.searchFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)

                Text("OR")
                    .font(.retraceTinyBold)
                    .foregroundColor(.white.opacity(0.4))

                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Button(action: {
                withAnimation(.easeOut(duration: 0.12)) {
                    keyboardSelection = .calendar
                }
                openCalendarPicker()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.retraceCalloutMedium)
                    Text("Browse Calendar")
                        .font(.retraceCaptionMedium)
                }
                .foregroundColor(calendarButtonForegroundColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(calendarButtonBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(calendarButtonBorderColor, lineWidth: isCalendarKeyboardSelected ? 1.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isCalendarButtonHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.bottom, 16)
        .frame(width: TimelineScaleFactor.searchPanelWidth)
        .retraceMenuContainer(addPadding: false)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: RetraceMenuStyle.cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.15),
                                Color.white.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .shadow(color: .retraceAccent.opacity(0.1), radius: 60, y: 30)
        .offset(
            x: panelPosition.width + dragOffset.width,
            y: panelPosition.height + dragOffset.height
        )
        .onAppear {
            keyboardSelection = .input
        }
    }
}

struct SuggestionChip: View {
    let text: String
    let icon: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.retraceTinyMedium)
                Text(text)
                    .font(.retraceCaption2Medium)
            }
            .foregroundColor(isHovering ? .white : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovering ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isHovering ? 0.2 : 0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}
