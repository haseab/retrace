import SwiftUI
import Dispatch

// MARK: - Feedback Form View

public struct FeedbackFormView: View {

    // MARK: - Properties

    @StateObject private var viewModel: FeedbackViewModel
    @EnvironmentObject private var coordinatorWrapper: AppCoordinatorWrapper
    @Environment(\.dismiss) private var dismiss

    private let liveChatURL = URL(string: "https://retrace.to/chat")!
    private let launchContext: FeedbackLaunchContext?
    private let onSuccessfulSubmit: (() -> Void)?

    @FocusState private var focusedField: FocusedField?
    @State private var escapeKeyMonitor: Any?
    @State private var sendingPulseExpanded = false
    @State private var successIconScale: CGFloat = 0.72
    @State private var successIconOpacity = 0.0
    @State private var successBurstScale: CGFloat = 0.72
    @State private var successBurstOpacity = 0.0
    @State private var successTextOpacity = 0.0
    @State private var successTextOffset: CGFloat = 14
    @State private var measuredFormContentHeight: CGFloat = 0
    @State private var measuredFormFooterHeight: CGFloat = 0
    @State private var feedbackWindowNumber: Int?
    @State private var keyboardFocusTarget: KeyboardFocusTarget = .description
    @State private var suppressAutomaticFocusScroll = true
    @StateObject private var scrollLatch = HoverLatchedScrollMonitor<ScrollTarget>(
        hoverPriority: [.details],
        defaultTarget: .outer
    )

    private enum FocusedField {
        case email
        case description
    }

    private enum ScrollTarget {
        case outer
        case details
    }

    private enum KeyboardFocusTarget: Hashable {
        case email
        case description
        case details
        case diagnosticSection(DiagnosticInfo.SectionID)
        case attachScreenshot
        case downloadReport
        case submit
    }

    private enum PresentationState: Equatable {
        case form
        case submitting
        case failure
        case success
    }

    private enum FormContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private enum FormFooterHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    public init(
        launchContext: FeedbackLaunchContext? = nil,
        onSuccessfulSubmit: (() -> Void)? = nil
    ) {
        self.launchContext = launchContext
        self.onSuccessfulSubmit = onSuccessfulSubmit
        _viewModel = StateObject(wrappedValue: FeedbackViewModel(launchContext: launchContext))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            backgroundView
            contentView
        }
        .frame(width: 480, height: containerHeight)
        .clipped()
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: presentationState)
        .background(
            FeedbackWindowObserver { windowNumber in
                feedbackWindowNumber = windowNumber
                if viewModel.showDiagnosticsDetail {
                    installScrollMonitorIfNeeded()
                }
            }
        )
        .onAppear {
            suppressAutomaticFocusScroll = true
            viewModel.setCoordinator(coordinatorWrapper)
            setupEscapeKeyHandler()
            applyInitialFocusIfNeeded()
        }
        .onDisappear {
            removeEscapeKeyHandler()
            removeScrollMonitor()
            viewModel.teardown()
        }
        .onChange(of: viewModel.isSubmitting) { isSubmitting in
            guard isSubmitting else { return }
            beginSendingAnimations()
        }
        .onChange(of: viewModel.isSubmitted) { isSubmitted in
            guard isSubmitted else { return }
            playSuccessAnimation()
            onSuccessfulSubmit?()
        }
        .onChange(of: focusedField) { newValue in
            switch newValue {
            case .email:
                keyboardFocusTarget = .email
            case .description:
                keyboardFocusTarget = .description
            case nil:
                break
            }
        }
        .onChange(of: viewModel.feedbackType) { _ in
            ensureKeyboardFocusIsValid()
        }
        .onChange(of: viewModel.showDiagnosticsDetail) { isExpanded in
            ensureKeyboardFocusIsValid()
            if isExpanded {
                installScrollMonitorIfNeeded()
            } else {
                removeScrollMonitor()
            }
        }
    }

    // MARK: - Escape Key Handling

    @ViewBuilder
    private var contentView: some View {
        switch presentationState {
        case .form:
            formView
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .submitting:
            submittingView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        case .failure:
            submissionFailureView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        case .success:
            successView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        }
    }

    private var presentationState: PresentationState {
        if viewModel.isSubmitted {
            return .success
        }
        if viewModel.isSubmitting {
            return .submitting
        }
        if viewModel.hasSubmissionFailure {
            return .failure
        }
        return .form
    }

    private var containerHeight: CGFloat {
        switch presentationState {
        case .form:
            let measuredHeight = measuredFormContentHeight + measuredFormFooterHeight
            return min(540, max(0, measuredHeight))
        case .submitting, .failure, .success:
            return 540
        }
    }

    private func setupEscapeKeyHandler() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 { // Escape key
                if viewModel.isSubmitting {
                    return nil
                }
                dismiss()
                return nil // Consume the event
            }

            if presentationState == .form {
                if handleCommandSubmitShortcut(event) {
                    return nil
                }
                if handleTabNavigation(event) {
                    return nil
                }
                if handleFocusedControlActivation(event) {
                    return nil
                }
            }
            return event
        }
    }

    private func removeEscapeKeyHandler() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    private var isOuterScrollDisabled: Bool {
        viewModel.showDiagnosticsDetail && scrollLatch.latchedTarget == .details
    }

    private var isDiagnosticsScrollEnabled: Bool {
        switch scrollLatch.latchedTarget {
        case .outer:
            return false
        case .details, .none:
            return true
        }
    }

    private func installScrollMonitorIfNeeded() {
        guard viewModel.showDiagnosticsDetail else { return }

        scrollLatch.installMonitorIfNeeded { event in
            guard let feedbackWindowNumber else { return false }
            return event.window?.windowNumber == feedbackWindowNumber
        }
    }

    private func removeScrollMonitor() {
        scrollLatch.removeMonitor()
    }

    private func applyInitialFocusIfNeeded() {
        let initialTarget: KeyboardFocusTarget = launchContext?.preferredFocusField == .email ? .email : .description
        DispatchQueue.main.async {
            self.setKeyboardFocus(initialTarget)
            DispatchQueue.main.async {
                self.suppressAutomaticFocusScroll = false
            }
        }
    }

    private var formKeyboardOrder: [KeyboardFocusTarget] {
        var order: [KeyboardFocusTarget] = [
            .email,
            .description,
            .details,
        ]
        if viewModel.showDiagnosticsDetail {
            order.append(contentsOf: viewModel.diagnosticSections.map {
                .diagnosticSection($0.id)
            })
        }
        order.append(.attachScreenshot)
        order.append(.downloadReport)
        order.append(.submit)
        return order
    }

    private func ensureKeyboardFocusIsValid() {
        guard presentationState == .form else { return }
        if !formKeyboardOrder.contains(keyboardFocusTarget),
           let fallback = formKeyboardOrder.first {
            setKeyboardFocus(fallback)
        }
    }

    private func setKeyboardFocus(_ target: KeyboardFocusTarget) {
        keyboardFocusTarget = target
        switch target {
        case .email:
            focusedField = .email
        case .description:
            focusedField = .description
        case .details, .diagnosticSection(_), .attachScreenshot, .downloadReport, .submit:
            focusedField = nil
        }
    }

    private func moveKeyboardFocus(forward: Bool) {
        let order = formKeyboardOrder
        guard !order.isEmpty else { return }

        guard let currentIndex = order.firstIndex(of: keyboardFocusTarget) else {
            setKeyboardFocus(order[0])
            return
        }

        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % order.count
        } else {
            nextIndex = (currentIndex - 1 + order.count) % order.count
        }
        setKeyboardFocus(order[nextIndex])
    }

    private func handleTabNavigation(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48 else { return false } // Tab
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else {
            return false
        }

        moveKeyboardFocus(forward: !event.modifierFlags.contains(.shift))
        return true
    }

    private func handleCommandSubmitShortcut(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return false }
        guard event.modifierFlags.contains(.command) else { return false }
        guard viewModel.canSubmit else { return true }

        Task { await viewModel.submit() }
        return true
    }

    private func handleFocusedControlActivation(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return false }
        guard !event.modifierFlags.contains(.command) else { return false }

        switch keyboardFocusTarget {
        case .details:
            toggleDiagnosticsDetail()
            return true
        case .diagnosticSection(let section):
            viewModel.toggleDiagnosticSection(section)
            return true
        case .attachScreenshot:
            viewModel.selectImageFromFinder()
            return true
        case .downloadReport:
            if viewModel.canExport {
                Task { await viewModel.exportFeedbackReport() }
            }
            return true
        case .submit:
            if viewModel.canSubmit {
                Task { await viewModel.submit() }
            }
            return true
        case .email, .description:
            return false
        }
    }

    private func toggleDiagnosticsDetail() {
        let shouldLoad = !viewModel.showDiagnosticsDetail

        withAnimation(.easeOut(duration: 0.16)) {
            viewModel.showDiagnosticsDetail.toggle()
        }

        guard shouldLoad else { return }

        // Defer loading one runloop so the expanded state renders immediately.
        DispatchQueue.main.async {
            viewModel.loadDiagnosticsIfNeeded()
        }
    }

    private func scrollAnchorTarget(for target: KeyboardFocusTarget) -> KeyboardFocusTarget? {
        switch target {
        case .email, .description, .details, .diagnosticSection(_), .attachScreenshot, .downloadReport:
            return target
        case .submit:
            // Submit is in the fixed footer and already visible.
            return nil
        }
    }

    private func scrollToFocusedControl(_ target: KeyboardFocusTarget, proxy: ScrollViewProxy) {
        guard !suppressAutomaticFocusScroll,
              let anchorTarget = scrollAnchorTarget(for: target) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(anchorTarget, anchor: .center)
            }
        }
    }

    private func beginSendingAnimations() {
        sendingPulseExpanded = false

        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            sendingPulseExpanded = true
        }
    }

    private func playSuccessAnimation() {
        successIconScale = 0.72
        successIconOpacity = 0
        successBurstScale = 0.72
        successBurstOpacity = 0.42
        successTextOpacity = 0
        successTextOffset = 14

        withAnimation(.spring(response: 0.5, dampingFraction: 0.74)) {
            successIconScale = 1
            successIconOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.7).delay(0.04)) {
            successBurstScale = 1.3
            successBurstOpacity = 0
        }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.84).delay(0.12)) {
            successTextOpacity = 1
            successTextOffset = 0
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        ZStack {
            Color.retraceBackground

            // Subtle gradient orbs for depth
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.retraceAccent.opacity(0.08), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: -150, y: -200)
                .blur(radius: 50)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 139/255, green: 92/255, blue: 246/255).opacity(0.06), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 180, y: 200)
                .blur(radius: 40)
        }
    }

    // MARK: - Form View

    private var formView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Header
                        header

                        // Feedback Type Picker
                        feedbackTypeSection

                        // Email
                        emailSection
                            .id(KeyboardFocusTarget.email)

                        // Description
                        descriptionSection
                            .id(KeyboardFocusTarget.description)

                        diagnosticsSection
                            .id(KeyboardFocusTarget.details)

                        // Image Attachment
                        imageAttachmentSection
                            .id(KeyboardFocusTarget.attachScreenshot)

                        // Manual export fallback directly under screenshot attachment
                        offlineExportCard
                            .id(KeyboardFocusTarget.downloadReport)

                        // Error
                        if let error = viewModel.error {
                            errorBanner(error)
                        }
                    }
                    .padding(20)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: FormContentHeightKey.self,
                                    value: geometry.size.height
                                )
                        }
                    )
                }
                .scrollDisabled(isOuterScrollDisabled)
                .onChange(of: keyboardFocusTarget) { newValue in
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(newValue, proxy: proxy)
                }
                .onAppear {
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(keyboardFocusTarget, proxy: proxy)
                }
                .onChange(of: viewModel.showDiagnosticsDetail) { _ in
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(keyboardFocusTarget, proxy: proxy)
                }
            }
            actionButtons
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 20)
                .background(Color.retraceBackground)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.22),
                            Color.black.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                    .allowsHitTesting(false)
                }
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: FormFooterHeightKey.self,
                        value: geometry.size.height
                    )
                }
            )
        }
        .onPreferenceChange(FormContentHeightKey.self) { newValue in
            if abs(newValue - measuredFormContentHeight) > 0.5 {
                measuredFormContentHeight = newValue
            }
        }
        .onPreferenceChange(FormFooterHeightKey.self) { newValue in
            if abs(newValue - measuredFormFooterHeight) > 0.5 {
                measuredFormFooterHeight = newValue
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.retraceAccentGradient.opacity(0.2))
                        .frame(width: 36, height: 36)

                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LinearGradient.retraceAccentGradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Feedback")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.retracePrimary)

                    Text("Help us improve Retrace")
                        .font(.system(size: 11))
                        .foregroundColor(.retraceSecondary)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.retraceSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Feedback Type Section

    private var feedbackTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            HStack(spacing: 8) {
                ForEach(FeedbackType.allCases) { type in
                    feedbackTypeButton(type)
                }
            }
        }
    }

    private func feedbackTypeButton(_ type: FeedbackType) -> some View {
        let isSelected = viewModel.feedbackType == type

        return Button(action: { viewModel.setFeedbackType(type) }) {
            HStack(spacing: 5) {
                Image(systemName: type.icon)
                    .font(.system(size: 11, weight: .medium))
                Text(type.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .retracePrimary : .retraceSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.retraceAccent.opacity(0.15) : Color.white.opacity(0.03))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.retraceAccent.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Email Section

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            TextField("your@email.com", text: $viewModel.email)
                .font(.retraceCaption)
                .foregroundColor(.retracePrimary)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .email)
                .onTapGesture {
                    keyboardFocusTarget = .email
                }
                .padding(10)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            viewModel.showEmailError
                                ? Color.retraceDanger.opacity(0.5)
                                : (keyboardFocusTarget == .email ? Color.retraceAccent.opacity(0.7) : Color.white.opacity(0.06)),
                            lineWidth: 1
                        )
                )

            if viewModel.showEmailError {
                Text("Please enter a valid email address")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceDanger)
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.retraceCaptionBold)
                .foregroundColor(.retracePrimary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.description)
                    .font(.retraceCaption)
                    .foregroundColor(.retracePrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .description)
                    .onTapGesture {
                        keyboardFocusTarget = .description
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                keyboardFocusTarget == .description
                                    ? Color.retraceAccent.opacity(0.7)
                                    : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    )

                if viewModel.description.isEmpty {
                    Text(viewModel.feedbackType.placeholder)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceSecondary.opacity(0.5))
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.retraceCaption2Medium)
                        .foregroundColor(.retraceSecondary)
                    Text("What's Included")
                        .font(.retraceCaptionBold)
                        .foregroundColor(.retracePrimary)
                }

                Spacer()

                Button(action: {
                    keyboardFocusTarget = .details
                    toggleDiagnosticsDetail()
                }) {
                    HStack(spacing: 4) {
                        Text(viewModel.showDiagnosticsDetail ? "Hide" : "Details")
                            .font(.retraceCaption2Medium)
                        Image(systemName: viewModel.showDiagnosticsDetail ? "chevron.up" : "chevron.down")
                            .font(.retraceTinyBold)
                    }
                    .foregroundStyle(LinearGradient.retraceAccentGradient)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        keyboardFocusTarget == .details
                            ? Color.retraceAccent.opacity(0.12)
                            : Color.clear
                    )
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                keyboardFocusTarget == .details
                                    ? Color.retraceAccent.opacity(0.6)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            // Compact summary - single line
            HStack(spacing: 12) {
                diagnosticChip(icon: "app.badge", text: "Version")
                diagnosticChip(icon: "desktopcomputer", text: "Device")
                diagnosticChip(icon: "cylinder", text: "Stats")
                diagnosticChip(icon: "memorychip", text: "Memory")
                if viewModel.includesLogsInDiagnostics {
                    diagnosticChip(icon: "doc.text", text: "Logs")
                }
            }

            if viewModel.includesLogsInDiagnostics {
                Text("Bug reports include recent logs plus a hierarchical Retrace memory summary from the system monitor sampler.")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceSecondary.opacity(0.72))
            } else {
                Text("Retrace also attaches a local app and system snapshot for support. Expand details to exclude anything you don't want to share.")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceSecondary.opacity(0.72))
            }

            // Expanded details (lazy loaded)
            if viewModel.showDiagnosticsDetail {
                Divider()
                    .background(Color.white.opacity(0.06))

                if viewModel.diagnostics != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Uncheck any section you don't want included with this report.")
                            .font(.system(size: 10))
                            .foregroundColor(.retraceSecondary.opacity(0.72))

                        if viewModel.excludedDiagnosticSectionCount > 0 {
                            Text("\(viewModel.excludedDiagnosticSectionCount) section\(viewModel.excludedDiagnosticSectionCount == 1 ? "" : "s") currently excluded")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.58))
                        }

                        ScrollView(showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(viewModel.diagnosticSections) { section in
                                    diagnosticSectionCard(section)
                                        .id(KeyboardFocusTarget.diagnosticSection(section.id))
                                }
                            }
                            .padding(8)
                        }
                        .scrollDisabled(!isDiagnosticsScrollEnabled)
                        .frame(height: 280)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6)
                        .clipped()
                        .onHover { hovering in
                            scrollLatch.updateHoveredTarget(.details, isHovering: hovering)
                        }

                        if !viewModel.hasSelectedDiagnosticSections {
                            Text("No diagnostics will be attached beyond your written description and any screenshot you add.")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary.opacity(0.58))
                        }
                    }
                } else {
                    HStack {
                        SpinnerView(size: 16, lineWidth: 2)
                        Text("Loading diagnostics...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: viewModel.showDiagnosticsDetail)
        .padding(12)
        .background(Color.white.opacity(0.03))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func diagnosticChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.retraceSecondary)
    }

    private func diagnosticSectionCard(_ section: DiagnosticInfo.SectionSummary) -> some View {
        let isIncluded = viewModel.isDiagnosticSectionIncluded(section.id)
        let isFocused = keyboardFocusTarget == .diagnosticSection(section.id)

        return VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                keyboardFocusTarget = .diagnosticSection(section.id)
                viewModel.toggleDiagnosticSection(section.id)
            }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isIncluded ? .retraceAccent : .retraceSecondary.opacity(0.75))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.retracePrimary)

                            if let countSummary = section.countSummary {
                                Text(countSummary)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.retraceSecondary.opacity(0.82))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(999)
                            }
                        }

                        Text(section.reason)
                            .font(.system(size: 10))
                            .foregroundColor(.retraceSecondary.opacity(0.74))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(isIncluded ? "Included" : "Excluded")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isIncluded ? .retraceAccent : .retraceSecondary.opacity(0.72))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            (isIncluded ? Color.retraceAccent.opacity(0.14) : Color.white.opacity(0.04))
                        )
                        .cornerRadius(999)
                }
            }
            .buttonStyle(.plain)

            Text(section.preview)
                .font(.retraceMonoSmall)
                .foregroundColor(
                    isIncluded
                        ? .retraceSecondary
                        : .retraceSecondary.opacity(0.58)
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    isIncluded
                        ? Color.black.opacity(0.16)
                        : Color.black.opacity(0.1)
                )
                .cornerRadius(6)

            if let previewDisclosure = section.previewDisclosure {
                Text(previewDisclosure)
                    .font(.system(size: 9))
                    .foregroundColor(.retraceSecondary.opacity(0.58))
            }
        }
        .padding(10)
        .background(
            isIncluded
                ? Color.white.opacity(0.035)
                : Color.white.opacity(0.015)
        )
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFocused
                        ? Color.retraceAccent.opacity(0.64)
                        : Color.white.opacity(isIncluded ? 0.08 : 0.04),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Image Attachment Section

    @State private var isDropTargeted = false

    private var imageAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = viewModel.attachedImage {
                // Show attached image preview
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 50)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image attached")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.retracePrimary)
                        if let data = viewModel.attachedImageData {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                                .font(.system(size: 10))
                                .foregroundColor(.retraceSecondary)
                        }
                    }

                    Spacer()

                    Button(action: { viewModel.removeAttachedImage() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.retraceSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.retraceAccent.opacity(0.3), lineWidth: 1)
                )
            } else {
                // Drop zone / select button
                Button(action: {
                    keyboardFocusTarget = .attachScreenshot
                    viewModel.selectImageFromFinder()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 12))
                            .foregroundColor(.retraceSecondary)
                        Text("Attach image")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.retraceSecondary)
                        Spacer()
                        Text("Drop or click")
                            .font(.system(size: 10))
                            .foregroundColor(.retraceSecondary.opacity(0.6))
                    }
                    .padding(10)
                    .background(isDropTargeted ? Color.retraceAccent.opacity(0.1) : Color.white.opacity(0.03))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isDropTargeted ? Color.retraceAccent.opacity(0.5) : Color.white.opacity(0.06),
                                style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [4])
                            )
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                    handleImageDrop(providers)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    keyboardFocusTarget == .attachScreenshot
                        ? Color.retraceAccent.opacity(0.6)
                        : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try to load as image directly
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { image, error in
                if let nsImage = image as? NSImage {
                    Task { @MainActor in
                        viewModel.attachImage(nsImage)
                    }
                }
            }
            return true
        }

        // Try to load as file URL
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        viewModel.attachImage(from: url)
                    }
                }
            }
            return true
        }

        return false
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.retraceCallout)
                .foregroundColor(.retraceDanger)
            Text(message)
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceDanger)
            Spacer()
        }
        .padding(14)
        .background(Color.retraceDanger.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.retraceDanger.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSubmitting || viewModel.isExporting)

            Button(action: {
                keyboardFocusTarget = .submit
                Task { await viewModel.submit() }
            }) {
                Text("Send Feedback")
                    .font(.retraceCalloutBold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(viewModel.canSubmit ? Color.retraceAccent : Color.retraceAccent.opacity(0.4))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            keyboardFocusTarget == .submit
                                ? Color.white.opacity(0.85)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
        }
        .padding(.top, 4)
    }

    private var offlineExportCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LinearGradient.retraceAccentGradient)
                .frame(width: 30, height: 30)
                .background(Color.retraceAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Need to send it manually?")
                    .font(.retraceCaptionBold)
                    .foregroundColor(.retracePrimary)

                Text("Download the report to your Desktop as a .txt file. If you attached an image, Retrace saves it next to the text file.")
                    .font(.system(size: 10))
                    .foregroundColor(.retraceSecondary.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: {
                keyboardFocusTarget = .downloadReport
                Task { await viewModel.exportFeedbackReport() }
            }) {
                HStack(spacing: 6) {
                    if viewModel.isExporting {
                        SpinnerView(size: 12, lineWidth: 2, color: .white)
                    }
                    Text(viewModel.isExporting ? "Preparing..." : "Download .txt")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(viewModel.canExport ? Color.retraceAccent : Color.retraceAccent.opacity(0.4))
                .cornerRadius(9)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(
                            keyboardFocusTarget == .downloadReport
                                ? Color.white.opacity(0.85)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canExport)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Submitting View

    private var submittingView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 18)

            submissionProgressOrb

            VStack(spacing: 8) {
                Text("Sending feedback")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)
                    .multilineTextAlignment(.center)

                Group {
                    Text(viewModel.submissionDetail)
                        .id(viewModel.submissionStage)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .font(.retraceBodyMedium)
                .foregroundColor(.retraceSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: viewModel.submissionStage)

            Spacer()

            Text("Please keep this window open while we finish the upload.")
                .font(.retraceCaptionMedium)
                .foregroundColor(.retraceSecondary.opacity(0.78))
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 56)
    }

    private var submissionFailureView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.retraceDanger.opacity(0.16))
                    .frame(width: 110, height: 110)
                    .blur(radius: 18)

                Circle()
                    .fill(Color.retraceDanger.opacity(0.12))
                    .frame(width: 84, height: 84)

                Image(systemName: viewModel.submissionFailureSymbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.retraceDanger)
            }

            VStack(spacing: 8) {
                Text(viewModel.submissionFailureTitle)
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)
                    .multilineTextAlignment(.center)

                Text(viewModel.submissionFailureDetail)
                    .font(.retraceBodyMedium)
                    .foregroundColor(.retraceSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

            if viewModel.submissionFailureIsNetworkRelated {
                Button(action: { Task { await viewModel.exportFeedbackReport() } }) {
                    HStack(spacing: 8) {
                        if viewModel.isExporting {
                            SpinnerView(size: 14, lineWidth: 2, color: .white)
                        }
                        Text(viewModel.isExporting ? "Preparing..." : "Download .txt")
                            .font(.retraceCalloutBold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(viewModel.canExport ? Color.retraceAccent : Color.retraceAccent.opacity(0.4))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canExport)
            }

            Button(action: { viewModel.clearSubmissionFailure() }) {
                Text("Back")
                    .font(.retraceCalloutMedium)
                    .foregroundColor(.retraceSecondary)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 56)
    }

    private var submissionProgressOrb: some View {
        ZStack {
            Circle()
                .fill(Color.retraceAccent.opacity(0.14))
                .frame(width: 100, height: 100)
                .blur(radius: sendingPulseExpanded ? 18 : 12)
                .scaleEffect(sendingPulseExpanded ? 1.06 : 0.94)

            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 8)
                .frame(width: 88, height: 88)

            Circle()
                .trim(from: 0, to: max(0.06, viewModel.submissionProgress))
                .stroke(
                    LinearGradient.retraceAccentGradient,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))
                .shadow(color: Color.retraceAccent.opacity(0.42), radius: 14, x: 0, y: 0)

            SpinnerView(size: 20, lineWidth: 2.2, color: .white.opacity(0.92))
        }
        .frame(width: 100, height: 100)
        .padding(.bottom, 6)
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.retraceSuccess.opacity(0.32), lineWidth: 2)
                    .frame(width: 112, height: 112)
                    .scaleEffect(successBurstScale)
                    .opacity(successBurstOpacity)

                Circle()
                    .fill(Color.retraceSuccess.opacity(0.15))
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.retraceSuccess.opacity(0.3), Color.retraceSuccess.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 88, height: 88)
                    .scaleEffect(successIconScale)

                Image(systemName: "checkmark")
                    .font(.retraceDisplay2)
                    .foregroundColor(.retraceSuccess)
                    .scaleEffect(successIconScale)
                    .opacity(successIconOpacity)
            }
            .offset(y: successTextOffset * -0.35)

            VStack(spacing: 8) {
                Text("Feedback Sent!")
                    .font(.retraceMediumNumber)
                    .foregroundColor(.retracePrimary)

                Text("Thanks for helping improve Retrace.")
                    .font(.retraceBodyMedium)
                    .foregroundColor(.retraceSecondary)
            }
            .opacity(successTextOpacity)
            .offset(y: successTextOffset)

            Spacer()

            // Live chat link
            VStack(spacing: 14) {
                Text("Need a faster response?")
                    .font(.retraceCaptionMedium)
                    .foregroundColor(.retraceSecondary)

                Link(destination: liveChatURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                            .font(.retraceCallout)
                        Text("Chat with me on retrace.to")
                            .font(.retraceCalloutMedium)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.retraceAccent.opacity(0.3))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.retraceAccent.opacity(0.5), lineWidth: 1)
                    )
                }
            }

            Spacer()

            // Close button
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.white)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(Color.retraceAccent)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(28)
    }
}

private struct FeedbackWindowObserver: NSViewRepresentable {
    let onWindowNumberChange: (Int?) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onWindowNumberChange: onWindowNumberChange)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onWindowNumberChange = onWindowNumberChange
        nsView.reportWindowNumberIfNeeded()
    }

    final class ObserverView: NSView {
        var onWindowNumberChange: (Int?) -> Void
        private var lastReportedWindowNumber: Int?

        init(onWindowNumberChange: @escaping (Int?) -> Void) {
            self.onWindowNumberChange = onWindowNumberChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowNumberIfNeeded()
        }

        func reportWindowNumberIfNeeded() {
            let windowNumber = window?.windowNumber
            guard windowNumber != lastReportedWindowNumber else { return }
            lastReportedWindowNumber = windowNumber

            DispatchQueue.main.async { [windowNumber, onWindowNumberChange] in
                onWindowNumberChange(windowNumber)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FeedbackFormView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackFormView()
            .preferredColorScheme(.dark)
    }
}
#endif
