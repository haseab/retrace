import SwiftUI
import AppKit

enum CommentEditorCommand: Equatable {
    case bold
    case italic
    case link(url: String)
}

struct CommentMarkdownEditor: NSViewRepresentable {
    struct FormattingBridge {
        let command: CommentEditorCommand
        let commandNonce: Int
        let onRequestLink: (() -> Void)?
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: (() -> Void)?
    let formatting: FormattingBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textStorage = NSTextStorage(
            attributedString: Coordinator.attributedString(fromMarkdown: text)
        )
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = CommentMarkdownTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.commandHandler = { command in
            context.coordinator.apply(command: command, in: textView)
        }
        textView.requestLinkHandler = {
            context.coordinator.parent.formatting?.onRequestLink?()
        }
        textView.submitHandler = {
            context.coordinator.parent.onSubmit?()
        }

        scrollView.documentView = textView
        context.coordinator.normalizeEditorAttributes(in: textView)
        textView.typingAttributes = Coordinator.baseTypingAttributes
        context.coordinator.lastSerializedMarkdown = text
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CommentMarkdownTextView else { return }
        context.coordinator.parent = self

        if context.coordinator.lastSerializedMarkdown != text {
            context.coordinator.isApplyingProgrammaticUpdate = true
            context.coordinator.replaceContents(of: textView, withMarkdown: text)
            context.coordinator.isApplyingProgrammaticUpdate = false
            context.coordinator.lastSerializedMarkdown = text
        }

        if let formatting,
           context.coordinator.lastHandledCommandNonce != formatting.commandNonce {
            context.coordinator.lastHandledCommandNonce = formatting.commandNonce
            context.coordinator.apply(command: formatting.command, in: textView)
        }

        textView.submitHandler = {
            context.coordinator.parent.onSubmit?()
        }
        textView.requestLinkHandler = {
            context.coordinator.parent.formatting?.onRequestLink?()
        }

        if isFocused, let window = textView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommentMarkdownEditor
        var isApplyingProgrammaticUpdate = false
        var lastHandledCommandNonce: Int?
        var lastSerializedMarkdown: String = ""

        private static let baseFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        private static let baseColor = NSColor(white: 0.95, alpha: 1.0)
        private static let linkColor = NSColor(red: 0.56, green: 0.76, blue: 0.98, alpha: 1.0)
        private static let inlinePresentationIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        private static let headingLevelAttributeKey = NSAttributedString.Key("RetraceHeadingLevel")
        private static let markdownParsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )

        static let baseTypingAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor
        ]

        private enum InlineStyle {
            case bold
            case italic
        }

        private struct HeadingShortcut {
            let level: Int
            let markerLength: Int
        }

        init(parent: CommentMarkdownEditor) {
            self.parent = parent
            self.lastHandledCommandNonce = parent.formatting?.commandNonce
            self.lastSerializedMarkdown = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingProgrammaticUpdate else { return }

            isApplyingProgrammaticUpdate = true
            applyHeadingShortcutIfNeeded(in: textView)
            normalizeEditorAttributes(in: textView)
            syncMarkdownBinding(from: textView)
            isApplyingProgrammaticUpdate = false
        }

        func apply(command: CommentEditorCommand, in textView: NSTextView) {
            isApplyingProgrammaticUpdate = true
            switch command {
            case .bold:
                toggle(style: .bold, in: textView)
            case .italic:
                toggle(style: .italic, in: textView)
            case .link(let urlString):
                insertLink(in: textView, urlString: urlString)
            }
            normalizeEditorAttributes(in: textView)
            syncMarkdownBinding(from: textView)
            isApplyingProgrammaticUpdate = false
        }

        private func insertLink(in textView: NSTextView, urlString: String) {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return }
            guard let storage = textView.textStorage else { return }
            guard let url = Self.normalizeLink(urlString) else { return }

            if selectedRange.length == 0 {
                let placeholder = "link text"
                textView.insertText(placeholder, replacementRange: selectedRange)
                let insertedRange = NSRange(location: selectedRange.location, length: (placeholder as NSString).length)
                applyLinkAttributes(in: insertedRange, storage: storage, url: url)
                textView.setSelectedRange(insertedRange)
                return
            }

            applyLinkAttributes(in: selectedRange, storage: storage, url: url)
            textView.setSelectedRange(selectedRange)
        }

        private func applyLinkAttributes(in range: NSRange, storage: NSTextStorage, url: URL?) {
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
            if let url {
                attributes[.link] = url
            }
            storage.addAttributes(attributes, range: range)
        }

        private func toggle(style: InlineStyle, in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            guard selectedRange.location != NSNotFound else { return }

            if selectedRange.length == 0 {
                var typingAttributes = textView.typingAttributes
                let currentFont = normalizeFont(typingAttributes[.font] as? NSFont)
                let shouldEnable = !font(currentFont, contains: style)
                typingAttributes[.font] = font(currentFont, setting: style, enabled: shouldEnable)
                typingAttributes[.foregroundColor] = Self.baseColor
                textView.typingAttributes = typingAttributes
                return
            }

            guard let storage = textView.textStorage else { return }
            let shouldEnable = !selectionFullyContains(style: style, range: selectedRange, storage: storage)
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: selectedRange, options: []) { value, range, _ in
                let currentFont = normalizeFont(value as? NSFont)
                let updatedFont = font(currentFont, setting: style, enabled: shouldEnable)
                storage.addAttribute(.font, value: updatedFont, range: range)
            }
            storage.endEditing()
            textView.setSelectedRange(selectedRange)
        }

        private func selectionFullyContains(style: InlineStyle, range: NSRange, storage: NSTextStorage) -> Bool {
            var allStyled = true
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let currentFont = normalizeFont(value as? NSFont)
                if !self.font(currentFont, contains: style) {
                    allStyled = false
                    stop.pointee = true
                }
            }
            return allStyled
        }

        func replaceContents(of textView: NSTextView, withMarkdown markdown: String) {
            guard let storage = textView.textStorage else { return }
            let attributed = Self.attributedString(fromMarkdown: markdown)
            storage.setAttributedString(attributed)
            normalizeEditorAttributes(in: textView)
            let insertionPoint = NSRange(location: storage.length, length: 0)
            textView.setSelectedRange(insertionPoint)
            textView.typingAttributes = Self.baseTypingAttributes
        }

        private func syncMarkdownBinding(from textView: NSTextView) {
            let markdown = Self.markdownString(from: textView.attributedString())
            lastSerializedMarkdown = markdown
            parent.text = markdown
        }

        private func applyHeadingShortcutIfNeeded(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = storage.string as NSString
            guard source.length > 0 else { return }

            let selection = textView.selectedRange()
            guard selection.location != NSNotFound else { return }

            let lineLookupLocation = min(max(selection.location, 0), max(source.length - 1, 0))
            let lineRange = source.lineRange(for: NSRange(location: lineLookupLocation, length: 0))
            let contentRange = Self.lineContentRange(from: lineRange, in: source)
            guard contentRange.length > 0 else { return }

            let lineText = source.substring(with: contentRange)
            guard let shortcut = Self.parseHeadingShortcut(in: lineText) else { return }
            guard shortcut.markerLength > 0, shortcut.markerLength <= contentRange.length else { return }

            let markerRange = NSRange(location: contentRange.location, length: shortcut.markerLength)
            storage.replaceCharacters(in: markerRange, with: "")

            let updatedLineRange = NSRange(
                location: contentRange.location,
                length: max(0, contentRange.length - shortcut.markerLength)
            )
            if updatedLineRange.length > 0 {
                storage.addAttribute(Self.headingLevelAttributeKey, value: shortcut.level, range: updatedLineRange)
            }

            var adjustedSelection = selection
            let markerUpperBound = markerRange.location + markerRange.length
            if adjustedSelection.location >= markerUpperBound {
                adjustedSelection.location -= markerRange.length
            } else if adjustedSelection.location > markerRange.location {
                adjustedSelection.location = markerRange.location
            }
            if adjustedSelection.length > 0 {
                let selectionEnd = selection.location + selection.length
                let overlapStart = max(selection.location, markerRange.location)
                let overlapEnd = min(selectionEnd, markerUpperBound)
                if overlapEnd > overlapStart {
                    adjustedSelection.length = max(0, adjustedSelection.length - (overlapEnd - overlapStart))
                }
            }
            adjustedSelection.location = min(adjustedSelection.location, storage.length)
            textView.setSelectedRange(adjustedSelection)

            var typing = textView.typingAttributes
            typing[.font] = Self.headingBaseFont(for: shortcut.level)
            typing[.foregroundColor] = Self.baseColor
            typing[Self.headingLevelAttributeKey] = shortcut.level
            textView.typingAttributes = typing
        }

        private func normalizeHeadingAttributes(in storage: NSTextStorage) {
            let source = storage.string as NSString
            guard source.length > 0 else { return }

            var lineStart = 0
            while lineStart < source.length {
                let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
                let contentRange = Self.lineContentRange(from: lineRange, in: source)

                if contentRange.length > 0 {
                    if let level = Self.headingLevel(in: storage, range: contentRange) {
                        storage.addAttribute(Self.headingLevelAttributeKey, value: level, range: contentRange)
                    } else {
                        storage.removeAttribute(Self.headingLevelAttributeKey, range: contentRange)
                    }
                }

                let newlineLength = lineRange.length - contentRange.length
                if newlineLength > 0 {
                    let newlineRange = NSRange(location: contentRange.location + contentRange.length, length: newlineLength)
                    storage.removeAttribute(Self.headingLevelAttributeKey, range: newlineRange)
                }

                lineStart = lineRange.location + lineRange.length
            }
        }

        func normalizeEditorAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            guard fullRange.length > 0 else {
                textView.typingAttributes = Self.baseTypingAttributes
                return
            }

            let selectedRanges = textView.selectedRanges

            storage.beginEditing()
            normalizeHeadingAttributes(in: storage)
            storage.addAttribute(.foregroundColor, value: Self.baseColor, range: fullRange)
            storage.addAttribute(.underlineStyle, value: 0, range: fullRange)

            storage.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
                let currentFont = normalizeFont(attributes[.font] as? NSFont)
                let headingLevel = Self.headingLevelValue(from: attributes[Self.headingLevelAttributeKey])

                var targetFont = headingLevel.map(Self.headingBaseFont(for:)) ?? Self.baseFont
                let traits = currentFont.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italic) {
                    targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: targetFont, range: range)
            }

            storage.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
                guard Self.normalizeLink(value) != nil else { return }
                storage.addAttributes(
                    [
                        .foregroundColor: Self.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            storage.endEditing()
            textView.setSelectedRanges(selectedRanges, affinity: .downstream, stillSelecting: false)
            textView.typingAttributes = typingAttributes(for: textView)
        }

        private func typingAttributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            let currentFont = normalizeFont(textView.typingAttributes[.font] as? NSFont)

            var headingLevel: Int?
            if let storage = textView.textStorage, storage.length > 0 {
                let source = storage.string as NSString
                let selection = textView.selectedRange()
                let location = min(max(selection.location, 0), max(source.length - 1, 0))
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                let contentRange = Self.lineContentRange(from: lineRange, in: source)
                headingLevel = Self.headingLevel(in: storage, range: contentRange)
            }

            var targetFont = headingLevel.map(Self.headingBaseFont(for:)) ?? Self.baseFont
            let traits = currentFont.fontDescriptor.symbolicTraits
            if traits.contains(.bold) {
                targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italic) {
                targetFont = NSFontManager.shared.convert(targetFont, toHaveTrait: .italicFontMask)
            }

            var result: [NSAttributedString.Key: Any] = [
                .font: targetFont,
                .foregroundColor: Self.baseColor
            ]
            if let headingLevel {
                result[Self.headingLevelAttributeKey] = headingLevel
            }
            return result
        }

        private func normalizeFont(_ font: NSFont?) -> NSFont {
            let source = font ?? Self.baseFont
            let descriptor = source.fontDescriptor.symbolicTraits
            var normalized = Self.baseFont
            if descriptor.contains(.bold) {
                normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .boldFontMask)
            }
            if descriptor.contains(.italic) {
                normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .italicFontMask)
            }
            return normalized
        }

        private func font(_ font: NSFont, contains style: InlineStyle) -> Bool {
            let traits = font.fontDescriptor.symbolicTraits
            switch style {
            case .bold:
                return traits.contains(.bold)
            case .italic:
                return traits.contains(.italic)
            }
        }

        private func font(_ base: NSFont, setting style: InlineStyle, enabled: Bool) -> NSFont {
            let trait: NSFontTraitMask = {
                switch style {
                case .bold:
                    return .boldFontMask
                case .italic:
                    return .italicFontMask
                }
            }()

            if enabled {
                return NSFontManager.shared.convert(base, toHaveTrait: trait)
            }
            return NSFontManager.shared.convert(base, toNotHaveTrait: trait)
        }

        static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
            let normalized = markdown
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            guard !normalized.isEmpty else {
                return NSAttributedString(string: "", attributes: baseTypingAttributes)
            }

            let output = NSMutableAttributedString()
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

            for (index, line) in lines.enumerated() {
                if let shortcut = parseHeadingShortcut(in: line) {
                    let contentStart = line.index(line.startIndex, offsetBy: min(shortcut.markerLength, line.count))
                    let content = String(line[contentStart...])
                    let attributedLine = attributedInlineString(fromInlineMarkdown: content)
                    if attributedLine.length > 0 {
                        attributedLine.addAttribute(headingLevelAttributeKey, value: shortcut.level, range: NSRange(location: 0, length: attributedLine.length))
                    }
                    output.append(attributedLine)
                } else {
                    output.append(attributedInlineString(fromInlineMarkdown: line))
                }

                if index < lines.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: baseTypingAttributes))
                }
            }

            return output
        }

        private static func attributedInlineString(fromInlineMarkdown markdown: String) -> NSMutableAttributedString {
            guard let parsed = try? AttributedString(markdown: markdown, options: markdownParsingOptions) else {
                return NSMutableAttributedString(string: markdown, attributes: baseTypingAttributes)
            }

            let source = NSAttributedString(parsed)
            let output = NSMutableAttributedString(string: source.string, attributes: baseTypingAttributes)
            let fullRange = NSRange(location: 0, length: output.length)
            guard fullRange.length > 0 else { return output }

            source.enumerateAttribute(inlinePresentationIntentKey, in: fullRange, options: []) { value, range, _ in
                guard let intent = inlineIntent(from: value) else { return }
                var font = baseFont
                if intent.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                output.addAttribute(.font, value: font, range: range)
            }

            source.enumerateAttribute(.link, in: fullRange, options: []) { value, range, _ in
                guard let link = normalizeLink(value) else { return }
                output.addAttributes(
                    [
                        .link: link,
                        .foregroundColor: linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ],
                    range: range
                )
            }

            return output
        }

        static func markdownString(from attributedText: NSAttributedString) -> String {
            guard attributedText.length > 0 else { return "" }

            let source = attributedText.string as NSString
            var lineStart = 0
            var lines: [String] = []

            while lineStart < source.length {
                let lineRange = source.lineRange(for: NSRange(location: lineStart, length: 0))
                let contentRange = lineContentRange(from: lineRange, in: source)
                let headingLevel = headingLevel(in: attributedText, range: contentRange)

                var lineMarkdown = markdownInlineString(
                    from: attributedText,
                    range: contentRange,
                    suppressBoldFromHeading: headingLevel != nil
                )
                if let headingLevel {
                    lineMarkdown = "\(String(repeating: "#", count: headingLevel)) \(lineMarkdown)"
                }
                lines.append(lineMarkdown)
                lineStart = lineRange.location + lineRange.length
            }

            var markdown = lines.joined(separator: "\n")
            if source.character(at: source.length - 1) == 10 {
                markdown += "\n"
            }
            return markdown
        }

        private static func markdownInlineString(
            from attributedText: NSAttributedString,
            range: NSRange,
            suppressBoldFromHeading: Bool
        ) -> String {
            guard range.length > 0 else { return "" }

            let source = attributedText.string as NSString
            var markdown = ""
            var index = range.location
            let end = range.location + range.length

            while index < end {
                var effectiveRange = NSRange(location: 0, length: 0)
                let attributes = attributedText.attributes(
                    at: index,
                    longestEffectiveRange: &effectiveRange,
                    in: range
                )
                let segment = source.substring(with: effectiveRange)
                markdown += markdownFragment(
                    for: segment,
                    attributes: attributes,
                    suppressBoldFromHeading: suppressBoldFromHeading
                )
                index = effectiveRange.location + effectiveRange.length
            }

            return markdown
        }

        private static func headingLevel(in attributedText: NSAttributedString, range: NSRange) -> Int? {
            guard range.length > 0 else { return nil }
            var foundLevel: Int?
            attributedText.enumerateAttribute(
                headingLevelAttributeKey,
                in: range,
                options: [.longestEffectiveRangeNotRequired]
            ) { value, _, stop in
                if let level = headingLevelValue(from: value) {
                    foundLevel = level
                    stop.pointee = true
                }
            }
            return foundLevel
        }

        private static func headingLevelValue(from value: Any?) -> Int? {
            let level: Int?
            if let intValue = value as? Int {
                level = intValue
            } else if let numberValue = value as? NSNumber {
                level = numberValue.intValue
            } else {
                level = nil
            }
            guard let level, (1...6).contains(level) else { return nil }
            return level
        }

        private static func lineContentRange(from lineRange: NSRange, in source: NSString) -> NSRange {
            guard lineRange.length > 0 else { return lineRange }
            let lineEnd = lineRange.location + lineRange.length
            if lineEnd > 0, lineEnd <= source.length, source.character(at: lineEnd - 1) == 10 {
                return NSRange(location: lineRange.location, length: lineRange.length - 1)
            }
            return lineRange
        }

        private static func headingBaseFont(for level: Int) -> NSFont {
            let size = headingPointSize(for: level)
            return NSFont.systemFont(ofSize: size, weight: .regular)
        }

        private static func headingPointSize(for level: Int) -> CGFloat {
            max(13.0, 20.0 - (CGFloat(level - 1) * 1.8))
        }

        private static func parseHeadingShortcut(in line: String) -> HeadingShortcut? {
            let source = line as NSString
            guard source.length > 1 else { return nil }

            var index = 0
            var level = 0
            while index < source.length, source.character(at: index) == 35, level < 6 {
                level += 1
                index += 1
            }

            guard level > 0, index < source.length else { return nil }
            guard let firstWhitespaceScalar = UnicodeScalar(Int(source.character(at: index))),
                  CharacterSet.whitespaces.contains(firstWhitespaceScalar) else {
                return nil
            }

            while index < source.length,
                  let scalar = UnicodeScalar(Int(source.character(at: index))),
                  CharacterSet.whitespaces.contains(scalar) {
                index += 1
            }

            return HeadingShortcut(level: level, markerLength: index)
        }

        private static func markdownFragment(
            for segment: String,
            attributes: [NSAttributedString.Key: Any],
            suppressBoldFromHeading: Bool
        ) -> String {
            guard !segment.isEmpty else { return "" }

            if let link = normalizeLink(attributes[.link]) {
                let text = escapeMarkdownText(segment)
                let destination = link.absoluteString.replacingOccurrences(of: ")", with: "%29")
                return "[\(text)](\(destination))"
            }

            let font = attributes[.font] as? NSFont ?? baseFont
            let traits = font.fontDescriptor.symbolicTraits
            let isBold = traits.contains(.bold) && !suppressBoldFromHeading
            let isItalic = traits.contains(.italic)

            let escaped = escapeMarkdownText(segment)
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return escaped
            }

            if isBold && isItalic {
                return "***\(escaped)***"
            }
            if isBold {
                return "**\(escaped)**"
            }
            if isItalic {
                return "*\(escaped)*"
            }
            return escaped
        }

        private static func escapeMarkdownText(_ text: String) -> String {
            var escaped = ""
            escaped.reserveCapacity(text.count)

            for character in text {
                switch character {
                case "\\", "*", "_", "[", "]", "(", ")":
                    escaped.append("\\")
                    escaped.append(character)
                default:
                    escaped.append(character)
                }
            }
            return escaped
        }

        private static func inlineIntent(from value: Any?) -> InlinePresentationIntent? {
            if let intent = value as? InlinePresentationIntent {
                return intent
            }
            if let number = value as? NSNumber {
                return InlinePresentationIntent(rawValue: number.uintValue)
            }
            return nil
        }

        private static func normalizeLink(_ value: Any?) -> URL? {
            if let url = value as? URL {
                return url
            }
            if let string = value as? String {
                return URL(string: string)
            }
            if let string = value as? NSString {
                return URL(string: string as String)
            }
            return nil
        }
    }
}

class CommentMarkdownTextView: NSTextView {
    var commandHandler: ((CommentEditorCommand) -> Void)?
    var submitHandler: (() -> Void)?
    var requestLinkHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if isSubmitKeyEquivalent(event), let submitHandler {
            submitHandler()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSubmitKeyEquivalent(event), let submitHandler {
            submitHandler()
            return true
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "a":
            selectAll(nil)
            return true
        case "c":
            copy(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "b":
            commandHandler?(.bold)
            return true
        case "i":
            commandHandler?(.italic)
            return true
        case "k":
            if let requestLinkHandler {
                requestLinkHandler()
                return true
            }
            return super.performKeyEquivalent(with: event)
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func isSubmitKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == [.command] else { return false }
        return event.keyCode == 36 || event.keyCode == 76
    }
}
