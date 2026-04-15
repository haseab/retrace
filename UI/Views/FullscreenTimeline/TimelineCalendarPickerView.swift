import SwiftUI
import AppKit

struct CalendarPickerView: View {
    @ObservedObject var viewModel: SimpleTimelineViewModel

    @State private var displayedMonth: Date = Date()
    @GestureState private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGSize = .zero

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            calendarView
                .frame(width: TimelineScaleFactor.calendarPickerWidth)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 20)

            timeListView
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(white: 0.08))

                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.03)],
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
            syncDisplayedMonthToSelection()
        }
        .onChange(of: viewModel.selectedCalendarDate) { _ in
            syncDisplayedMonthToSelection()
        }
    }

    private var calendarView: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Jump to Date & Time")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.top, 14)
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

            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

                Spacer()

                Text(monthYearString)
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.retraceCaption2Bold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { day in
                    Text(day)
                        .font(.retraceTinyMedium)
                        .foregroundColor(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            let days = daysInMonth()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    dayCell(for: day)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
    }

    private var timeListView: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40)

            LazyVGrid(
                columns: [
                    GridItem(.fixed(58), spacing: 6),
                    GridItem(.fixed(58), spacing: 6),
                    GridItem(.fixed(58), spacing: 6)
                ],
                spacing: 6
            ) {
                ForEach(0..<24, id: \.self) { hour in
                    let hasFrames = hourHasFrames(hour)
                    let isKeyboardSelected =
                        viewModel.calendarKeyboardFocus == .timeGrid &&
                        viewModel.selectedCalendarHour == hour
                    TimeSlotButton(
                        hourValue: hour,
                        hasFrames: hasFrames,
                        isKeyboardSelected: isKeyboardSelected,
                        selectedDate: viewModel.selectedCalendarDate
                    ) {
                        if let actualTimestamp = getFirstFrameTimestamp(forHour: hour) {
                            viewModel.calendarKeyboardFocus = .timeGrid
                            viewModel.selectedCalendarHour = hour
                            Task {
                                await viewModel.navigateToHour(actualTimestamp)
                            }
                        }
                    }
                    .frame(width: 58)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 210)
        .clipped()
    }

    private func hourHasFrames(_ hour: Int) -> Bool {
        guard viewModel.selectedCalendarDate != nil else { return false }
        let cal = Calendar.current
        return viewModel.hoursWithFrames.contains { date in
            cal.component(.hour, from: date) == hour
        }
    }

    private func getFirstFrameTimestamp(forHour hour: Int) -> Date? {
        let cal = Calendar.current
        return viewModel.hoursWithFrames.first { date in
            cal.component(.hour, from: date) == hour
        }
    }

    private func dayCell(for day: Date?) -> some View {
        Group {
            if let day = day {
                let normalizedDay = calendar.startOfDay(for: day)
                let isToday = calendar.isDateInToday(normalizedDay)
                let isSelected = viewModel.selectedCalendarDate.map { calendar.isDate($0, inSameDayAs: normalizedDay) } ?? false
                let hasFrames = dateHasFrames(normalizedDay)
                let isCurrentMonth = calendar.isDate(normalizedDay, equalTo: displayedMonth, toGranularity: .month)

                Button(action: {
                    if hasFrames {
                        viewModel.focusCalendarDateGrid()
                        viewModel.selectedCalendarDate = normalizedDay
                        viewModel.selectedCalendarHour = nil
                        viewModel.hoursWithFrames = []
                        Task {
                            await viewModel.loadHoursForDate(normalizedDay)
                        }
                    }
                }) {
                    ZStack {
                        Text("\(calendar.component(.day, from: normalizedDay))")
                            .font(isToday ? .retraceCaptionBold : .retraceCaption)
                            .foregroundColor(
                                hasFrames
                                    ? (isSelected ? .white : .white.opacity(isCurrentMonth ? 0.9 : 0.4))
                                    : .white.opacity(isCurrentMonth ? 0.25 : 0.1)
                            )
                            .frame(width: 32, height: 32)
                            .background(
                                ZStack {
                                    if isSelected {
                                        Circle()
                                            .fill(RetraceMenuStyle.actionBlue)
                                        if viewModel.calendarKeyboardFocus == .dateGrid {
                                            Circle()
                                                .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                                        }
                                    } else if isToday {
                                        Circle()
                                            .stroke(RetraceMenuStyle.actionBlue, lineWidth: 1.5)
                                    }
                                }
                            )
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier(Self.dayAccessibilityIdentifier(for: normalizedDay, calendar: calendar))
                .buttonStyle(.plain)
                .disabled(!hasFrames)
                .onHover { h in
                    if hasFrames {
                        if h { NSCursor.pointingHand.push() }
                        else { NSCursor.pop() }
                    }
                }
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedMonth = newMonth
            }
        }
    }

    private func daysInMonth() -> [Date?] {
        var days: [Date?] = []

        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return days
        }

        var currentDate = monthFirstWeek.start

        for _ in 0..<42 {
            if calendar.isDate(currentDate, equalTo: displayedMonth, toGranularity: .month) {
                days.append(currentDate)
            } else if currentDate < monthInterval.start {
                days.append(currentDate)
            } else if days.count < 35 || days.suffix(7).contains(where: { $0 != nil && calendar.isDate($0!, equalTo: displayedMonth, toGranularity: .month) }) {
                days.append(currentDate)
            } else {
                days.append(nil)
            }

            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        return days
    }

    private func dateHasFrames(_ date: Date) -> Bool {
        let startOfDay = calendar.startOfDay(for: date)
        return viewModel.datesWithFrames.contains(startOfDay)
    }

    private func syncDisplayedMonthToSelection() {
        guard let selectedDate = viewModel.selectedCalendarDate else { return }
        let targetMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: selectedDate)
        ) ?? selectedDate

        if !calendar.isDate(displayedMonth, equalTo: targetMonth, toGranularity: .month) {
            displayedMonth = targetMonth
        }
    }

    static func dayAccessibilityIdentifier(for day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "timeline-calendar-day-\(formatter.string(from: calendar.startOfDay(for: day)))"
    }
}

struct TimeSlotButton: View {
    let hourValue: Int
    let hasFrames: Bool
    let isKeyboardSelected: Bool
    let selectedDate: Date?
    let action: () -> Void

    @State private var isHovering = false

    private var timeString: String {
        String(format: "%02d:00", hourValue)
    }

    var body: some View {
        Button(action: action) {
            Text(timeString)
                .font(.retraceMono)
                .foregroundColor(
                    hasFrames
                        ? ((isHovering || isKeyboardSelected) ? .white : .white.opacity(0.9))
                        : .white.opacity(0.25)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            hasFrames
                                ? ((isHovering || isKeyboardSelected) ? RetraceMenuStyle.actionBlue : Color.white.opacity(0.1))
                                : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(isKeyboardSelected ? 0.95 : 0), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!hasFrames)
        .onHover { hovering in
            if hasFrames {
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
    }
}

struct DateSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let isCalendarSelected: () -> Bool
    let onMoveToCalendar: () -> Void
    let onMoveToInput: () -> Void
    let onCalendarSubmit: () -> Void
    let onInputClicked: () -> Void
    var placeholder: String = "Enter a date or time..."

    func makeNSView(context: Context) -> FocusableTextField {
        let textField = FocusableTextField()
        textField.placeholderString = placeholder
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 16, weight: .regular)
            ]
        )
        textField.font = .systemFont(ofSize: 16, weight: .regular)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.alignment = .left
        textField.delegate = context.coordinator
        textField.drawsBackground = false
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.usesSingleLineMode = true
        textField.isEditable = true
        textField.isSelectable = true
        textField.onCancelCallback = onCancel
        textField.onClickCallback = onInputClicked
        focusTextField(textField)
        return textField
    }

    func updateNSView(_ textField: FocusableTextField, context: Context) {
        textField.stringValue = text
        context.coordinator.updateCaretVisibility(
            for: textField,
            isCalendarSelected: isCalendarSelected()
        )
    }

    private func focusTextField(_ textField: FocusableTextField, attempt: Int = 1) {
        let maxAttempts = 5
        let delay: TimeInterval = attempt == 1 ? 0.0 : Double(attempt) * 0.05

        let schedule = {
            guard let window = textField.window else {
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.focusTextField(textField, attempt: attempt + 1)
                    }
                }
                return
            }
            self.performFocus(textField, in: window, attempt: attempt)
        }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: schedule)
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    private func performFocus(_ textField: FocusableTextField, in window: NSWindow, attempt: Int) {
        let maxAttempts = 5

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        let isKeyAfterMakeKey = window.isKeyWindow
        let success = window.makeFirstResponder(textField)

        if window.fieldEditor(false, for: textField) == nil {
            _ = window.fieldEditor(true, for: textField)
        }

        if !isKeyAfterMakeKey && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        } else if !success && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.focusTextField(textField, attempt: attempt + 1)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onCancel: onCancel,
            isCalendarSelected: isCalendarSelected,
            onMoveToCalendar: onMoveToCalendar,
            onMoveToInput: onMoveToInput,
            onCalendarSubmit: onCalendarSubmit
        )
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void
        let onCancel: () -> Void
        let isCalendarSelected: () -> Bool
        let onMoveToCalendar: () -> Void
        let onMoveToInput: () -> Void
        let onCalendarSubmit: () -> Void

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            isCalendarSelected: @escaping () -> Bool,
            onMoveToCalendar: @escaping () -> Void,
            onMoveToInput: @escaping () -> Void,
            onCalendarSubmit: @escaping () -> Void
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
            self.isCalendarSelected = isCalendarSelected
            self.onMoveToCalendar = onMoveToCalendar
            self.onMoveToInput = onMoveToInput
            self.onCalendarSubmit = onCalendarSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            if let textField = notification.object as? NSTextField {
                text = textField.stringValue
            }
        }

        func updateCaretVisibility(for textField: FocusableTextField, isCalendarSelected: Bool) {
            guard let window = textField.window,
                  let fieldEditor = window.fieldEditor(false, for: textField) as? NSTextView else {
                return
            }

            fieldEditor.insertionPointColor = isCalendarSelected ? .clear : .white
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if isCalendarSelected() {
                    onCalendarSubmit()
                } else {
                    onSubmit()
                }
                return true
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) ||
                        commandSelector == #selector(NSResponder.insertTab(_:)) {
                onMoveToCalendar()
                return true
            } else if commandSelector == #selector(NSResponder.moveUp(_:)) ||
                        commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                onMoveToInput()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}
