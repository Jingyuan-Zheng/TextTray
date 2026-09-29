import Cocoa
import FoundationModels
import SwiftUI
import Translation

private let defaultFontSize: CGFloat = 16
private let minimumFontSize: CGFloat = 12
private let maximumFontSize: CGFloat = 32

private enum InterfaceLanguage {
    case english
    case chinese
}

private struct ToolMessageError: LocalizedError {
    var errorDescription: String?
}

private enum PreferenceKey {
    static let language = "interfaceLanguage"
    static let fontSize = "fontSize"
    static let isPinned = "isPinned"
    static let showsLineNumbers = "showsLineNumbers"
    static let wrapsText = "wrapsText"
    static let showsStats = "showsStats"
}

private enum SaveTextFormat: CaseIterable {
    case plainText
    case markdown
    case json
    case csv
    case html
    case swift
    case python
    case javascript

    var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .markdown: return "md"
        case .json: return "json"
        case .csv: return "csv"
        case .html: return "html"
        case .swift: return "swift"
        case .python: return "py"
        case .javascript: return "js"
        }
    }

    var titleKey: String {
        switch self {
        case .plainText: return "saveAsPlainText"
        case .markdown: return "saveAsMarkdown"
        case .json: return "saveAsJSON"
        case .csv: return "saveAsCSV"
        case .html: return "saveAsHTML"
        case .swift: return "saveAsSwift"
        case .python: return "saveAsPython"
        case .javascript: return "saveAsJavaScript"
        }
    }
}

private func normalizedModifierFlags(from event: NSEvent) -> NSEvent.ModifierFlags {
    event.modifierFlags.intersection([.command, .shift, .option, .control])
}

private func readStandardInputText() -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return text
}

private func readClipboardText() -> String {
    NSPasteboard.general.string(forType: .string) ?? ""
}

private func readLaunchText() -> String {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.contains("--stdin") {
        return readStandardInputText()
    }

    if args.contains("--clipboard") {
        return readClipboardText()
    }

    if let separatorIndex = args.firstIndex(of: "--") {
        return args[(separatorIndex + 1)...].joined(separator: " ")
    }

    if let textIndex = args.firstIndex(of: "--text"), textIndex + 1 < args.count {
        return args[(textIndex + 1)...].joined(separator: " ")
    }

    let plainArgs = args.filter { !$0.hasPrefix("--") }
    if !plainArgs.isEmpty {
        return plainArgs.joined(separator: " ")
    }

    return readClipboardText()
}

private func decimal(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func normalizedLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

private func replacingMatches(
    in text: String,
    pattern: String,
    with replacement: String,
    options: NSRegularExpression.Options = []
) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
}

private func englishWordCount(in text: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9]+(?:[-'][A-Za-z0-9]+)*"#) else {
        return 0
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.numberOfMatches(in: text, range: range)
}

private func isCJK(_ scalar: UnicodeScalar) -> Bool {
    (0x4E00...0x9FFF).contains(Int(scalar.value))
        || (0x3400...0x4DBF).contains(Int(scalar.value))
        || (0x3040...0x30FF).contains(Int(scalar.value))
        || (0xAC00...0xD7AF).contains(Int(scalar.value))
}

private func firstScalar(in text: String) -> UnicodeScalar? {
    text.unicodeScalars.first
}

private func lastScalar(in text: String) -> UnicodeScalar? {
    text.unicodeScalars.last
}

private func looksLikeProtectedPDFLine(_ line: String) -> Bool {
    if line.hasPrefix("  ") || line.hasPrefix("\t") {
        return true
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
        return true
    }
    if trimmed.contains("|") {
        return true
    }

    let protectedPatterns = [
        #"^[-*•‣◦]\s+"#,
        #"^\d+[\.)]\s+"#,
        #"^[A-Za-z][\.)]\s+"#,
        #"^[ivxlcdmIVXLCDM]+[\.)]\s+"#
    ]

    return protectedPatterns.contains { pattern in
        trimmed.range(of: pattern, options: .regularExpression) != nil
    }
}

private func shouldJoinWithoutSpace(_ left: String, _ right: String) -> Bool {
    guard let last = lastScalar(in: left), let first = firstScalar(in: right) else {
        return false
    }
    return isCJK(last) || isCJK(first)
}

private func mergePDFLines(_ lines: [String]) -> String {
    var result = ""

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { continue }

        if result.isEmpty {
            result = line
            continue
        }

        if result.hasSuffix("-"),
           let nextScalar = firstScalar(in: line),
           CharacterSet.lowercaseLetters.contains(nextScalar) {
            result.removeLast()
            result += line
        } else if shouldJoinWithoutSpace(result, line) {
            result += line
        } else {
            result += " " + line
        }
    }

    return result
}

private func repairPDFLineBreaks(_ text: String) -> String {
    let normalized = normalizedLineEndings(text)
    var paragraphs: [[String]] = []
    var current: [String] = []

    for line in normalized.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if !current.isEmpty {
                paragraphs.append(current)
                current = []
            }
        } else {
            current.append(line)
        }
    }

    if !current.isEmpty {
        paragraphs.append(current)
    }

    let repaired = paragraphs.map { lines in
        var output: [String] = []
        var mergeBuffer: [String] = []

        func flushMergeBuffer() {
            if !mergeBuffer.isEmpty {
                output.append(mergePDFLines(mergeBuffer))
                mergeBuffer = []
            }
        }

        for line in lines {
            if looksLikeProtectedPDFLine(line) {
                flushMergeBuffer()
                output.append(line)
            } else {
                mergeBuffer.append(line)
            }
        }

        flushMergeBuffer()
        return output.joined(separator: "\n")
    }

    return repaired.joined(separator: "\n\n")
}

private func removeExtraBlankLines(_ text: String) -> String {
    let normalized = normalizedLineEndings(text)
    var lines: [String] = []
    var previousWasBlank = false

    for line in normalized.components(separatedBy: "\n") {
        let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if isBlank {
            if !previousWasBlank {
                lines.append("")
            }
        } else {
            lines.append(line)
        }
        previousWasBlank = isBlank
    }

    return lines.joined(separator: "\n")
}

private func trimTrailingWhitespacePerLine(_ text: String) -> String {
    normalizedLineEndings(text)
        .components(separatedBy: "\n")
        .map { replacingMatches(in: $0, pattern: #"[ \t]+$"#, with: "") }
        .joined(separator: "\n")
}

@available(macOS 26.0, *)
private func appleIntelligenceTransform(text: String, instruction: String) async throws -> String {
    let model = SystemLanguageModel.default
    guard model.isAvailable else {
        throw ToolMessageError(errorDescription: appleIntelligenceUnavailableMessage(for: model.availability))
    }

    let session = LanguageModelSession(
        model: model,
        instructions: """
        You are a concise text utility inside a temporary clipboard viewer.
        \(instruction)
        Return only the transformed text. Do not add explanations, headings, or markdown fences unless the user text requires them.
        """
    )
    let response = try await session.respond(to: text)
    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
}

@available(macOS 26.0, *)
private func appleIntelligenceUnavailableMessage(for availability: SystemLanguageModel.Availability) -> String {
    switch availability {
    case .available:
        return "Apple 智能当前可用。"
    case .unavailable(.deviceNotEligible):
        return "这台设备不符合 Apple 智能本地模型要求。"
    case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple 智能尚未启用。请在系统设置中启用后再试。"
    case .unavailable(.modelNotReady):
        return "Apple 智能模型尚未准备好，稍后再试。"
    @unknown default:
        return "Apple 智能当前不可用。"
    }
}

@available(macOS 26.0, *)
private func systemTranslate(text: String, targetLanguageCode: String) async throws -> String {
    let sourceLanguageCode = inferredSourceLanguageCode(for: text)
    guard sourceLanguageCode != targetLanguageCode else {
        throw ToolMessageError(errorDescription: "The text appears to already be in the target language.")
    }

    let session = TranslationSession(
        installedSource: Locale.Language(languageCode: Locale.LanguageCode(sourceLanguageCode)),
        target: Locale.Language(languageCode: Locale.LanguageCode(targetLanguageCode))
    )
    try await session.prepareTranslation()
    let response = try await session.translate(text)
    return response.targetText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
}

private func inferredSourceLanguageCode(for text: String) -> String {
    if text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains(Int($0.value)) }) {
        return "ja"
    }
    if text.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains(Int($0.value)) }) {
        return "ko"
    }
    if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains(Int($0.value)) }) {
        return "zh"
    }
    return "en"
}

private final class LineNumberRulerView: NSView {
    weak var textView: NSTextView?
    var ruleThickness: CGFloat = 38

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        updateRuleThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateRuleThickness() {
        guard let textView else {
            ruleThickness = 38
            invalidateIntrinsicContentSize()
            return
        }
        let lineCount = max(1, normalizedLineEndings(textView.string).components(separatedBy: "\n").count)
        let digits = max(2, String(lineCount).count)
        let fontSize = max(10, (textView.font?.pointSize ?? defaultFontSize) - 3)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)]).width
        ruleThickness = min(64, max(38, ceil(width + 18)))
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ruleThickness, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        updateRuleThickness()

        NSColor.clear.setFill()
        dirtyRect.fill()

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let text = textView.string as NSString
        var renderedLines = Set<Int>()

        let fontSize = max(10, (textView.font?.pointSize ?? defaultFontSize) - 3)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.46)
        ]

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentGlyphRange, _ in
            let characterIndex = layoutManager.characterIndexForGlyph(at: fragmentGlyphRange.location)
            let boundedIndex = min(characterIndex, text.length)
            let prefix = text.substring(to: boundedIndex)
            let lineNumber = prefix.reduce(1) { count, character in
                character == "\n" ? count + 1 : count
            }

            guard !renderedLines.contains(lineNumber) else { return }
            renderedLines.insert(lineNumber)

            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let y = usedRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            let drawRect = NSRect(
                x: self.ruleThickness - labelSize.width - 7,
                y: y,
                width: labelSize.width,
                height: labelSize.height
            )
            label.draw(in: drawRect, withAttributes: attributes)
        }
    }
}

final class TemporaryClipboardApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate {
    private let initialText: String

    private var window: NSWindow?
    private var rootView: NSVisualEffectView?
    private var scrollView: NSScrollView?
    private var textView: ClipboardTextView?
    private var lineNumberRuler: LineNumberRulerView?
    private var lineNumberWidthConstraint: NSLayoutConstraint?
    private var scrollLeadingWithLineNumbersConstraint: NSLayoutConstraint?
    private var scrollLeadingWithoutLineNumbersConstraint: NSLayoutConstraint?
    private var statusOverlay: NSVisualEffectView?
    private var statusBar: NSStackView?
    private var statsLabel: NSTextField?
    private var fontLabel: NSTextField?
    private var cursorLabel: NSTextField?
    private var progressHost: NSView?
    private var undoProcessItem: NSMenuItem?
    private var saveAsMenuItem: NSMenuItem?
    private var printMenuItem: NSMenuItem?
    private var copyAllMenuItem: NSMenuItem?
    private var clearTextMenuItem: NSMenuItem?
    private var keepOnTopMenuItem: NSMenuItem?
    private var lineNumbersMenuItem: NSMenuItem?
    private var wordWrapMenuItem: NSMenuItem?
    private var statsMenuItem: NSMenuItem?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollObserver: NSObjectProtocol?
    private var activeTask: Task<Void, Never>?
    private var statusRestoreWorkItem: DispatchWorkItem?
    private var statusHideWorkItem: DispatchWorkItem?

    private var language: InterfaceLanguage = .english
    private var lastLoadedText: String
    private var previousProcessedText: String?
    private var fontSize = defaultFontSize
    private var isPinned = true
    private var showsLineNumbers = true
    private var wrapsText = true
    private var showsStats = true
    private var isDestroying = false
    private var isProgrammaticTextChange = false
    private var isAsyncOperationRunning = false

    init(initialText: String) {
        self.initialText = initialText
        self.lastLoadedText = initialText
        super.init()
        loadPreferences()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        showWindow()
        updateTextState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        destroy(closeWindow: false, terminateApp: false)
    }

    func windowWillClose(_ notification: Notification) {
        destroy(closeWindow: false, terminateApp: true)
    }

    private func loadPreferences() {
        let defaults = UserDefaults.standard

        switch defaults.string(forKey: PreferenceKey.language) {
        case "chinese":
            language = .chinese
        case "english":
            language = .english
        default:
            break
        }

        if let savedFontSize = defaults.object(forKey: PreferenceKey.fontSize) as? Double {
            fontSize = min(maximumFontSize, max(minimumFontSize, CGFloat(savedFontSize)))
        }
        if let savedPinned = defaults.object(forKey: PreferenceKey.isPinned) as? Bool {
            isPinned = savedPinned
        }
        if let savedLineNumbers = defaults.object(forKey: PreferenceKey.showsLineNumbers) as? Bool {
            showsLineNumbers = savedLineNumbers
        }
        if let savedWrap = defaults.object(forKey: PreferenceKey.wrapsText) as? Bool {
            wrapsText = savedWrap
        }
        if let savedStats = defaults.object(forKey: PreferenceKey.showsStats) as? Bool {
            showsStats = savedStats
        }
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(language == .chinese ? "chinese" : "english", forKey: PreferenceKey.language)
        defaults.set(Double(fontSize), forKey: PreferenceKey.fontSize)
        defaults.set(isPinned, forKey: PreferenceKey.isPinned)
        defaults.set(showsLineNumbers, forKey: PreferenceKey.showsLineNumbers)
        defaults.set(wrapsText, forKey: PreferenceKey.wrapsText)
        defaults.set(showsStats, forKey: PreferenceKey.showsStats)
    }

    func textDidChange(_ notification: Notification) {
        if !isProgrammaticTextChange {
            previousProcessedText = nil
        }
        lineNumberRuler?.updateRuleThickness()
        updateLineNumberWidth()
        lineNumberRuler?.needsDisplay = true
        updateTextState()
        revealStatusTemporarily()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        lineNumberRuler?.needsDisplay = true
        updateTextState()
        revealStatusTemporarily()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        undoProcessItem?.isEnabled = previousProcessedText != nil
        let hasText = !(textView?.string.isEmpty ?? true)
        saveAsMenuItem?.isEnabled = hasText
        printMenuItem?.isEnabled = hasText
        copyAllMenuItem?.isEnabled = hasText
        clearTextMenuItem?.isEnabled = hasText
        keepOnTopMenuItem?.state = isPinned ? .on : .off
        lineNumbersMenuItem?.state = showsLineNumbers ? .on : .off
        wordWrapMenuItem?.state = wrapsText ? .on : .off
        statsMenuItem?.state = showsStats ? .on : .off
    }

    private func tr(_ key: String) -> String {
        switch language {
        case .english:
            switch key {
            case "windowTitle": return "Temporary Clipboard"
            case "appName": return "Text Tray"
            case "placeholder": return "No displayable text in Clipboard"
            case "pin": return "Keep on Top"
            case "aiMenu": return "AI"
            case "writingTools": return "Writing Tools"
            case "translate": return "Translate"
            case "process": return "Process"
            case "reload": return "Reload"
            case "reloadClipboard": return "Reload Clipboard"
            case "saveAs": return "Save As..."
            case "saveAsFormat": return "Save As Format"
            case "saveAsPlainText": return "Plain Text (.txt)"
            case "saveAsMarkdown": return "Markdown (.md)"
            case "saveAsJSON": return "JSON (.json)"
            case "saveAsCSV": return "CSV (.csv)"
            case "saveAsHTML": return "HTML (.html)"
            case "saveAsSwift": return "Swift (.swift)"
            case "saveAsPython": return "Python (.py)"
            case "saveAsJavaScript": return "JavaScript (.js)"
            case "saveAsCustomExtension": return "Custom Extension..."
            case "customExtensionTitle": return "Custom Extension"
            case "customExtensionInfo": return "Enter a file extension such as log, toml, cpp, or tex."
            case "customExtensionPlaceholder": return "extension"
            case "invalidExtension": return "Enter a valid extension using letters, numbers, hyphen, underscore, or plus."
            case "print": return "Print..."
            case "copyAll": return "Copy All"
            case "clear": return "Clear"
            case "clearText": return "Clear Text"
            case "destroy": return "Destroy"
            case "destroyClose": return "Destroy and Close"
            case "settings": return "Settings"
            case "about": return "About Text Tray"
            case "preferences": return "Preferences..."
            case "quit": return "Quit"
            case "fileMenu": return "File"
            case "editMenu": return "Edit"
            case "viewMenu": return "View"
            case "processingMenu": return "Process"
            case "language": return "Language"
            case "undo": return "Undo"
            case "redo": return "Redo"
            case "cut": return "Cut"
            case "copy": return "Copy"
            case "paste": return "Paste"
            case "selectAll": return "Select All"
            case "find": return "Find"
            case "extractTasks": return "Extract Tasks"
            case "extractDates": return "Extract Dates"
            case "extractAmounts": return "Extract Amounts"
            case "extractContacts": return "Extract Contacts"
            case "summarizeRequirements": return "Summarize Requirements"
            case "explainText": return "Explain Text"
            case "checkRisks": return "Check Risks"
            case "draftReply": return "Draft Reply"
            case "organizeChecklist": return "Organize as Checklist"
            case "organizeTable": return "Organize as Table"
            case "customPrompt": return "Custom Prompt..."
            case "aiResult": return "AI Result"
            case "copyResult": return "Copy Result"
            case "appendResult": return "Append to End"
            case "replaceOriginal": return "Replace Original"
            case "translateChinese": return "Translate to Chinese"
            case "translateEnglish": return "Translate to English"
            case "translateBilingual": return "Chinese-English Bilingual"
            case "trim": return "Trim"
            case "blankLines": return "Remove Blank Lines"
            case "pdfBreaks": return "Repair PDF Line Breaks"
            case "newlines": return "Normalize Newlines"
            case "trailingSpaces": return "Trim Line Endings"
            case "undoProcess": return "Undo Last Process"
            case "increaseFont": return "Increase Font Size"
            case "decreaseFont": return "Decrease Font Size"
            case "resetFont": return "Reset Font Size"
            case "showLineNumbers": return "Show Line Numbers"
            case "wordWrap": return "Word Wrap"
            case "showStats": return "Show Statistics"
            case "copied": return "Copied"
            case "saved": return "Saved"
            case "reloaded": return "Reloaded"
            case "chars": return "chars"
            case "words": return "words"
            case "lines": return "lines"
            case "selected": return "selected"
            case "confirmReplace": return "Replace current edits?"
            case "confirmReplaceInfo": return "This only replaces the temporary window text and does not change the system clipboard."
            case "continue": return "Continue"
            case "cancel": return "Cancel"
            case "ok": return "OK"
            case "noText": return "There is no text to process."
            case "aiVersion": return "Apple Intelligence actions require macOS 26 or later."
            case "translateVersion": return "System translation actions require macOS 26 or later."
            case "alreadyTarget": return "The text appears to already be in the target language."
            case "preferencesInfo": return "Language, pinning, font size, line numbers, word wrap, and statistics display are saved for future launches. Temporary text is never saved."
            case "customPromptMessage": return "Enter an instruction for the selected text or full document."
            case "customPromptPlaceholder": return "Instruction"
            default: return key
            }
        case .chinese:
            switch key {
            case "windowTitle": return "临时剪贴板"
            case "appName": return "Text Tray"
            case "placeholder": return "剪贴板中没有可显示的文字"
            case "pin": return "保持置顶"
            case "aiMenu": return "AI"
            case "writingTools": return "写作工具"
            case "translate": return "翻译"
            case "process": return "处理"
            case "reload": return "重新读取"
            case "reloadClipboard": return "重新读取剪贴板"
            case "saveAs": return "另存为…"
            case "saveAsFormat": return "另存格式"
            case "saveAsPlainText": return "纯文本（.txt）"
            case "saveAsMarkdown": return "Markdown（.md）"
            case "saveAsJSON": return "JSON（.json）"
            case "saveAsCSV": return "CSV（.csv）"
            case "saveAsHTML": return "HTML（.html）"
            case "saveAsSwift": return "Swift（.swift）"
            case "saveAsPython": return "Python（.py）"
            case "saveAsJavaScript": return "JavaScript（.js）"
            case "saveAsCustomExtension": return "自定义后缀…"
            case "customExtensionTitle": return "自定义后缀"
            case "customExtensionInfo": return "输入文件后缀，例如 log、toml、cpp 或 tex。"
            case "customExtensionPlaceholder": return "后缀"
            case "invalidExtension": return "请输入有效后缀，只使用字母、数字、连字符、下划线或加号。"
            case "print": return "打印…"
            case "copyAll": return "复制全部"
            case "clear": return "清空"
            case "clearText": return "清空文本"
            case "destroy": return "销毁"
            case "destroyClose": return "销毁并关闭"
            case "settings": return "设置"
            case "about": return "关于 Text Tray"
            case "preferences": return "偏好设置…"
            case "quit": return "退出"
            case "fileMenu": return "文件"
            case "editMenu": return "编辑"
            case "viewMenu": return "显示"
            case "processingMenu": return "处理"
            case "language": return "语言"
            case "undo": return "撤销"
            case "redo": return "重做"
            case "cut": return "剪切"
            case "copy": return "复制"
            case "paste": return "粘贴"
            case "selectAll": return "全选"
            case "find": return "查找"
            case "extractTasks": return "提取待办"
            case "extractDates": return "提取日期"
            case "extractAmounts": return "提取金额"
            case "extractContacts": return "提取联系人"
            case "summarizeRequirements": return "总结要求"
            case "explainText": return "解释这段文字"
            case "checkRisks": return "检查风险"
            case "draftReply": return "草拟回复"
            case "organizeChecklist": return "整理成清单"
            case "organizeTable": return "整理成表格"
            case "customPrompt": return "自定义指令…"
            case "aiResult": return "AI 结果"
            case "copyResult": return "复制结果"
            case "appendResult": return "追加到末尾"
            case "replaceOriginal": return "替换原文"
            case "translateChinese": return "翻译为中文"
            case "translateEnglish": return "翻译为英文"
            case "translateBilingual": return "中英对照"
            case "trim": return "去除首尾空白"
            case "blankLines": return "删除多余空行"
            case "pdfBreaks": return "合并 PDF 断行"
            case "newlines": return "统一换行符"
            case "trailingSpaces": return "去除每行末尾空格"
            case "undoProcess": return "撤销上一次处理"
            case "increaseFont": return "增大字体"
            case "decreaseFont": return "减小字体"
            case "resetFont": return "恢复默认字号"
            case "showLineNumbers": return "显示行号"
            case "wordWrap": return "自动换行"
            case "showStats": return "显示统计信息"
            case "copied": return "已复制"
            case "saved": return "已保存"
            case "reloaded": return "已重新读取"
            case "chars": return "字符"
            case "words": return "词"
            case "lines": return "行"
            case "selected": return "已选"
            case "confirmReplace": return "当前修改将被替换，是否继续？"
            case "confirmReplaceInfo": return "这只会替换窗口中的临时文本，不会修改系统剪贴板。"
            case "continue": return "继续"
            case "cancel": return "取消"
            case "ok": return "好"
            case "noText": return "当前没有可处理的文字。"
            case "aiVersion": return "Apple 智能操作需要 macOS 26 或更新版本。"
            case "translateVersion": return "系统翻译按钮需要 macOS 26 或更新版本。"
            case "alreadyTarget": return "文本看起来已经是目标语言。"
            case "preferencesInfo": return "语言、置顶、字号、行号、自动换行和统计信息显示会在下次启动时保留。临时文本不会保存。"
            case "customPromptMessage": return "输入要应用到选中文字或全文的指令。"
            case "customPromptPlaceholder": return "指令"
            default: return key
            }
        }
    }

    private func buildWindow() {
        let windowSize = NSSize(width: 900, height: 620)
        let windowFrame = centeredFrameOnMouseScreen(size: windowSize)

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = tr("windowTitle")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.acceptsMouseMovedEvents = true
        window.level = isPinned ? .floating : .normal
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = NSVisualEffectView(frame: NSRect(origin: .zero, size: windowSize))
        rootView.material = .windowBackground
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        let editorContainer = NSView()
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(editorContainer)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = ClipboardTextView()
        textView.owner = self
        textView.delegate = self
        textView.placeholder = tr("placeholder")
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapsText
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: wrapsText ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = wrapsText
        textView.textContainerInset = NSSize(width: 34, height: 32)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        configureWritingTools(for: textView)
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.string = initialText

        scrollView.documentView = textView
        let lineNumberRuler = LineNumberRulerView(textView: textView)
        lineNumberRuler.translatesAutoresizingMaskIntoConstraints = false
        lineNumberRuler.isHidden = !showsLineNumbers
        lineNumberRuler.updateRuleThickness()
        editorContainer.addSubview(lineNumberRuler)
        editorContainer.addSubview(scrollView)

        let statusOverlay = NSVisualEffectView()
        statusOverlay.material = .windowBackground
        statusOverlay.blendingMode = .withinWindow
        statusOverlay.state = .active
        statusOverlay.alphaValue = 0
        statusOverlay.isHidden = !showsStats
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(statusOverlay)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 5
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        footer.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(footer)

        let statsLabel = NSTextField(labelWithString: "")
        statsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statsLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.82)
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let fontLabel = NSTextField(labelWithString: "")
        fontLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fontLabel.textColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.82)

        let cursorLabel = NSTextField(labelWithString: "")
        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cursorLabel.textColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.78)

        let progressHost = NSHostingView(rootView: AnyView(ProgressView().controlSize(.small)))
        progressHost.translatesAutoresizingMaskIntoConstraints = false
        progressHost.isHidden = true

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        footer.addArrangedSubview(progressHost)
        footer.addArrangedSubview(statsLabel)
        footer.addArrangedSubview(fontLabel)
        footer.addArrangedSubview(statusSpacer)
        footer.addArrangedSubview(cursorLabel)

        let lineNumberWidthConstraint = lineNumberRuler.widthAnchor.constraint(equalToConstant: lineNumberRuler.ruleThickness)
        let scrollLeadingWithLineNumbersConstraint = scrollView.leadingAnchor.constraint(equalTo: lineNumberRuler.trailingAnchor)
        let scrollLeadingWithoutLineNumbersConstraint = scrollView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor)
        scrollLeadingWithLineNumbersConstraint.isActive = showsLineNumbers
        scrollLeadingWithoutLineNumbersConstraint.isActive = !showsLineNumbers

        NSLayoutConstraint.activate([
            editorContainer.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 28),
            editorContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            lineNumberRuler.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            lineNumberRuler.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            lineNumberRuler.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            lineNumberWidthConstraint,

            scrollView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),

            statusOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            statusOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            statusOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            statusOverlay.heightAnchor.constraint(equalToConstant: 30),

            footer.topAnchor.constraint(equalTo: statusOverlay.topAnchor),
            footer.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: statusOverlay.bottomAnchor),

            progressHost.widthAnchor.constraint(equalToConstant: 18),
            progressHost.heightAnchor.constraint(equalToConstant: 18)
        ])

        self.window = window
        self.rootView = rootView
        self.scrollView = scrollView
        self.textView = textView
        self.lineNumberRuler = lineNumberRuler
        self.lineNumberWidthConstraint = lineNumberWidthConstraint
        self.scrollLeadingWithLineNumbersConstraint = scrollLeadingWithLineNumbersConstraint
        self.scrollLeadingWithoutLineNumbersConstraint = scrollLeadingWithoutLineNumbersConstraint
        self.statusOverlay = statusOverlay
        self.statusBar = footer
        self.statsLabel = statsLabel
        self.fontLabel = fontLabel
        self.cursorLabel = cursorLabel
        self.progressHost = progressHost
        buildMainMenu()

        installEventMonitors()
        installScrollObserver()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu(title: tr("appName"))
        mainMenu.addItem(appMenuRoot())
        mainMenu.addItem(fileMenuRoot())
        mainMenu.addItem(editMenuRoot())
        mainMenu.addItem(menuRoot(title: tr("aiMenu"), submenu: buildIntelligenceMenu()))
        mainMenu.addItem(menuRoot(title: tr("translate"), submenu: buildTranslateMenu()))
        mainMenu.addItem(menuRoot(title: tr("processingMenu"), submenu: buildProcessMenu()))
        mainMenu.addItem(viewMenuRoot())
        NSApp.mainMenu = mainMenu
    }

    private func appMenuRoot() -> NSMenuItem {
        let menu = NSMenu(title: tr("appName"))
        menu.addItem(targetedMenuItem(title: tr("about"), action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(targetedMenuItem(title: tr("preferences"), action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(.separator())

        let languageMenu = NSMenu(title: tr("language"))
        languageMenu.addItem(targetedMenuItem(title: "English", action: #selector(useEnglishInterface), keyEquivalent: ""))
        languageMenu.addItem(targetedMenuItem(title: "中文", action: #selector(useChineseInterface), keyEquivalent: ""))
        let languageRoot = NSMenuItem(title: tr("language"), action: nil, keyEquivalent: "")
        languageRoot.submenu = languageMenu
        menu.addItem(languageRoot)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menuRoot(title: tr("appName"), submenu: menu)
    }

    private func fileMenuRoot() -> NSMenuItem {
        let menu = NSMenu(title: tr("fileMenu"))
        menu.delegate = self

        let reload = targetedMenuItem(
            title: tr("reloadClipboard"),
            action: #selector(rereadClipboardFromMenu),
            keyEquivalent: "r",
            modifiers: [.command, .shift]
        )
        menu.addItem(reload)

        let saveAs = targetedMenuItem(
            title: tr("saveAs"),
            action: #selector(saveAsFromMenu),
            keyEquivalent: "s",
            modifiers: [.command, .shift]
        )
        menu.addItem(saveAs)
        saveAsMenuItem = saveAs

        let saveFormatMenu = NSMenu(title: tr("saveAsFormat"))
        for format in SaveTextFormat.allCases {
            let item = NSMenuItem(
                title: tr(format.titleKey),
                action: #selector(saveAsFormatFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = format
            saveFormatMenu.addItem(item)
        }
        saveFormatMenu.addItem(.separator())
        let customExtensionItem = NSMenuItem(
            title: tr("saveAsCustomExtension"),
            action: #selector(saveAsCustomExtensionFromMenu),
            keyEquivalent: ""
        )
        customExtensionItem.target = self
        saveFormatMenu.addItem(customExtensionItem)

        let saveFormatRoot = NSMenuItem(title: tr("saveAsFormat"), action: nil, keyEquivalent: "")
        saveFormatRoot.submenu = saveFormatMenu
        menu.addItem(saveFormatRoot)

        let printItem = targetedMenuItem(
            title: tr("print"),
            action: #selector(printFromMenu),
            keyEquivalent: "p"
        )
        menu.addItem(printItem)
        printMenuItem = printItem

        menu.addItem(.separator())

        let copyAll = targetedMenuItem(
            title: tr("copyAll"),
            action: #selector(copyAllFromMenu),
            keyEquivalent: "c",
            modifiers: [.command, .shift]
        )
        menu.addItem(copyAll)
        copyAllMenuItem = copyAll

        menu.addItem(.separator())

        let clear = targetedMenuItem(
            title: tr("clearText"),
            action: #selector(clearTextFromMenu),
            keyEquivalent: "\u{8}",
            modifiers: [.command, .shift]
        )
        menu.addItem(clear)
        clearTextMenuItem = clear

        menu.addItem(targetedMenuItem(title: tr("destroyClose"), action: #selector(destroyFromShortcut), keyEquivalent: "w"))

        return menuRoot(title: tr("fileMenu"), submenu: menu)
    }

    private func editMenuRoot() -> NSMenuItem {
        let menu = NSMenu(title: tr("editMenu"))
        menu.addItem(NSMenuItem(title: tr("undo"), action: Selector(("undo:")), keyEquivalent: "z"))

        let redo = NSMenuItem(title: tr("redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr("cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: tr("copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: tr("paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        menu.addItem(NSMenuItem(title: tr("selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        menu.addItem(.separator())
        menu.addItem(targetedMenuItem(title: tr("find"), action: #selector(showFindFromMenu), keyEquivalent: "f"))
        return menuRoot(title: tr("editMenu"), submenu: menu)
    }

    private func viewMenuRoot() -> NSMenuItem {
        let menu = NSMenu(title: tr("viewMenu"))
        menu.delegate = self

        menu.addItem(targetedMenuItem(title: tr("increaseFont"), action: #selector(increaseFontSizeFromMenu), keyEquivalent: "+"))
        menu.addItem(targetedMenuItem(title: tr("decreaseFont"), action: #selector(decreaseFontSizeFromMenu), keyEquivalent: "-"))
        menu.addItem(targetedMenuItem(title: tr("resetFont"), action: #selector(resetFontSizeFromMenu), keyEquivalent: "0"))
        menu.addItem(.separator())

        let keepOnTop = targetedMenuItem(title: tr("pin"), action: #selector(togglePinnedFromMenu), keyEquivalent: "")
        let lineNumbers = targetedMenuItem(title: tr("showLineNumbers"), action: #selector(toggleLineNumbersFromMenu), keyEquivalent: "")
        let wordWrap = targetedMenuItem(title: tr("wordWrap"), action: #selector(toggleWordWrapFromMenu), keyEquivalent: "")
        let stats = targetedMenuItem(title: tr("showStats"), action: #selector(toggleStatsFromMenu), keyEquivalent: "")
        menu.addItem(keepOnTop)
        menu.addItem(lineNumbers)
        menu.addItem(wordWrap)
        menu.addItem(stats)

        keepOnTopMenuItem = keepOnTop
        lineNumbersMenuItem = lineNumbers
        wordWrapMenuItem = wordWrap
        statsMenuItem = stats

        return menuRoot(title: tr("viewMenu"), submenu: menu)
    }

    private func menuRoot(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func targetedMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func buildProcessMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        addProcessItem(tr("trim"), action: #selector(trimOuterWhitespace))
        addProcessItem(tr("blankLines"), action: #selector(deleteExtraBlankLines))
        addProcessItem(tr("pdfBreaks"), action: #selector(repairPDFBreaks))
        addProcessItem(tr("trailingSpaces"), action: #selector(trimTrailingWhitespace))
        addProcessItem(tr("newlines"), action: #selector(normalizeNewlines))
        menu.addItem(.separator())
        let undoItem = NSMenuItem(title: tr("undoProcess"), action: #selector(undoLastProcessing), keyEquivalent: "")
        undoItem.target = self
        undoItem.isEnabled = false
        menu.addItem(undoItem)
        undoProcessItem = undoItem
        return menu

        func addProcessItem(_ title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func buildIntelligenceMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(tr("extractTasks"), action: #selector(extractTasksWithAppleIntelligence))
        addItem(tr("extractDates"), action: #selector(extractDatesWithAppleIntelligence))
        addItem(tr("extractAmounts"), action: #selector(extractAmountsWithAppleIntelligence))
        addItem(tr("extractContacts"), action: #selector(extractContactsWithAppleIntelligence))
        menu.addItem(.separator())
        addItem(tr("summarizeRequirements"), action: #selector(summarizeRequirementsWithAppleIntelligence))
        addItem(tr("explainText"), action: #selector(explainTextWithAppleIntelligence))
        addItem(tr("checkRisks"), action: #selector(checkRisksWithAppleIntelligence))
        addItem(tr("draftReply"), action: #selector(draftReplyWithAppleIntelligence))
        menu.addItem(.separator())
        addItem(tr("organizeChecklist"), action: #selector(organizeChecklistWithAppleIntelligence))
        addItem(tr("organizeTable"), action: #selector(organizeTableWithAppleIntelligence))
        addItem(tr("customPrompt"), action: #selector(customPromptWithAppleIntelligence))
        return menu

        func addItem(_ title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func buildTranslateMenu() -> NSMenu {
        let menu = NSMenu()
        addItem(tr("translateChinese"), action: #selector(translateToChinese))
        addItem(tr("translateEnglish"), action: #selector(translateToEnglish))
        addItem(tr("translateBilingual"), action: #selector(translateBilingual))
        return menu

        func addItem(_ title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    private func configureWritingTools(for textView: NSTextView) {
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText, .richText, .list, .table]
            if #available(macOS 26.0, *) {
                textView.allowedWritingToolsResultOptions.insert(.presentationIntent)
            }
        }
    }

    private func refreshInterfaceText() {
        window?.title = tr("windowTitle")
        textView?.placeholder = tr("placeholder")

        buildMainMenu()
        updateTextState()
        textView?.needsDisplay = true
    }

    private func showWindow() {
        guard let window, let textView else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    @objc func destroyFromShortcut() {
        destroy(closeWindow: true, terminateApp: true)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutCredits()])
    }

    private func aboutCredits() -> NSAttributedString {
        let websiteURL = URL(string: "https://jingyuan-zheng.github.io")!
        let repositoryURL = URL(string: "https://github.com/Jingyuan-Zheng/TextTray")!
        let authorTitle = language == .chinese ? "作者：Jingyuan Zheng" : "Created by Jingyuan Zheng"
        let websiteTitle = language == .chinese ? "个人网站" : "Personal Website"
        let repositoryTitle = language == .chinese ? "GitHub 仓库" : "GitHub Repository"
        let openSourceTitle = language == .chinese ? "开源项目 · MIT 许可证" : "Open source · MIT License"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSMutableAttributedString(
            string: "\(authorTitle)\n\n\(websiteTitle)\n\(repositoryTitle)\n\n\(openSourceTitle)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle
            ]
        )
        let text = credits.string as NSString
        credits.addAttribute(.link, value: websiteURL, range: text.range(of: websiteTitle))
        credits.addAttribute(.link, value: repositoryURL, range: text.range(of: repositoryTitle))
        credits.addAttribute(.link, value: repositoryURL, range: text.range(of: openSourceTitle))
        return credits
    }

    @objc private func showPreferences() {
        showError(tr("preferencesInfo"))
    }

    @objc private func showFindFromMenu() {
        guard let textView else { return }
        window?.makeFirstResponder(textView)
        textView.showFindInterface()
    }

    @objc private func rereadClipboardFromMenu() {
        rereadClipboard(skipConfirm: false)
    }

    @objc private func copyAllFromMenu() {
        copyAllCurrentText()
    }

    @objc private func saveAsFromMenu() {
        saveCurrentTextAsFile()
    }

    @objc private func saveAsFormatFromMenu(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? SaveTextFormat else {
            saveCurrentTextAsFile()
            return
        }
        saveCurrentTextAsFile(format: format)
    }

    @objc private func saveAsCustomExtensionFromMenu() {
        guard let fileExtension = promptForCustomFileExtension() else { return }
        saveCurrentTextAsFile(fileExtension: fileExtension)
    }

    @objc private func printFromMenu() {
        printCurrentTextDocument()
    }

    @objc private func clearTextFromMenu() {
        clearTemporaryText()
    }

    @objc private func extractTasksWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("extractTasks"),
            instruction: "Extract concrete tasks, owners if present, and deadlines if present. Return a concise checklist. Keep the source language."
        )
    }

    @objc private func extractDatesWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("extractDates"),
            instruction: "Extract dates, times, deadlines, and date-related commitments. Include the surrounding context. Keep the source language."
        )
    }

    @objc private func extractAmountsWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("extractAmounts"),
            instruction: "Extract money amounts, prices, quantities, percentages, and numeric obligations. Include brief context. Keep the source language."
        )
    }

    @objc private func extractContactsWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("extractContacts"),
            instruction: "Extract names, organizations, roles, email addresses, phone numbers, and other contact-like details. Keep the source language."
        )
    }

    @objc private func summarizeRequirementsWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("summarizeRequirements"),
            instruction: "Summarize the requirements, constraints, acceptance criteria, and decisions in a practical bullet list. Keep the source language."
        )
    }

    @objc private func explainTextWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("explainText"),
            instruction: "Explain the text clearly and briefly. Define ambiguous terms and summarize the intent. Keep the source language."
        )
    }

    @objc private func checkRisksWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("checkRisks"),
            instruction: "Identify risks, ambiguities, missing information, and items that need confirmation. Keep the source language."
        )
    }

    @objc private func draftReplyWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("draftReply"),
            instruction: "Draft a concise reply to the text. Match the source language unless a different reply language is clearly implied."
        )
    }

    @objc private func organizeChecklistWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("organizeChecklist"),
            instruction: "Organize the text into a practical checklist. Preserve important details. Keep the source language."
        )
    }

    @objc private func organizeTableWithAppleIntelligence() {
        runAppleIntelligence(
            actionName: tr("organizeTable"),
            instruction: "Organize suitable information into a concise markdown table. Put non-tabular details below the table. Keep the source language."
        )
    }

    @objc private func customPromptWithAppleIntelligence() {
        guard let prompt = askForCustomPrompt() else { return }
        runAppleIntelligence(actionName: tr("customPrompt"), instruction: prompt)
    }

    @objc private func translateToChinese() {
        runSystemTranslation(actionName: tr("translateChinese"), targetLanguageCode: "zh")
    }

    @objc private func translateToEnglish() {
        runSystemTranslation(actionName: tr("translateEnglish"), targetLanguageCode: "en")
    }

    @objc private func translateBilingual() {
        guard let text = editableTextForTool() else { return }
        let target = inferredSourceLanguageCode(for: text) == "zh" ? "en" : "zh"
        runSystemTranslation(
            actionName: tr("translateBilingual"),
            targetLanguageCode: target,
            appendSourceText: true
        )
    }

    @objc private func useEnglishInterface() {
        language = .english
        savePreferences()
        refreshInterfaceText()
    }

    @objc private func useChineseInterface() {
        language = .chinese
        savePreferences()
        refreshInterfaceText()
    }

    @objc private func trimOuterWhitespace() {
        applyProcessing { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    @objc private func deleteExtraBlankLines() {
        applyProcessing(removeExtraBlankLines)
    }

    @objc private func repairPDFBreaks() {
        applyProcessing(repairPDFLineBreaks)
    }

    @objc private func normalizeNewlines() {
        applyProcessing(normalizedLineEndings)
    }

    @objc private func trimTrailingWhitespace() {
        applyProcessing(trimTrailingWhitespacePerLine)
    }

    @objc private func undoLastProcessing() {
        guard let previousProcessedText else { return }
        self.previousProcessedText = nil
        replaceEditorText(previousProcessedText, actionName: tr("undoProcess"))
    }

    private func rereadClipboard(skipConfirm: Bool) {
        guard let textView else { return }

        if textView.string != lastLoadedText, !skipConfirm {
            let alert = NSAlert()
            alert.messageText = tr("confirmReplace")
            alert.informativeText = tr("confirmReplaceInfo")
            alert.alertStyle = .warning
            alert.addButton(withTitle: tr("continue"))
            alert.addButton(withTitle: tr("cancel"))
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        let clipboardText = readClipboardText()
        lastLoadedText = clipboardText
        previousProcessedText = nil
        replaceEditorText(clipboardText, actionName: tr("reload"), registerUndo: false)
        showTemporaryStatus(tr("reloaded"))
    }

    private func copyAllCurrentText() {
        guard let text = textView?.string, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)

        showTemporaryStatus(tr("copied"))
    }

    fileprivate func saveCurrentTextAsFile(format: SaveTextFormat = .plainText) {
        saveCurrentTextAsFile(fileExtension: format.fileExtension)
    }

    private func saveCurrentTextAsFile(fileExtension: String) {
        guard let text = textView?.string, !text.isEmpty else {
            showError(tr("noText"))
            return
        }

        guard let url = chooseSaveURLWithAppleScript(
            defaultName: defaultSaveFileName(fileExtension: fileExtension),
            fallbackExtension: fileExtension
        ) else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showTemporaryStatus(tr("saved"))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func defaultSaveFileName(for format: SaveTextFormat) -> String {
        defaultSaveFileName(fileExtension: format.fileExtension)
    }

    private func defaultSaveFileName(fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Text_\(formatter.string(from: Date())).\(fileExtension)"
    }

    private func promptForCustomFileExtension() -> String? {
        let alert = NSAlert()
        alert.messageText = tr("customExtensionTitle")
        alert.informativeText = tr("customExtensionInfo")
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("continue"))
        alert.addButton(withTitle: tr("cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = tr("customExtensionPlaceholder")
        input.stringValue = "log"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let normalized = normalizedCustomFileExtension(input.stringValue) else {
            showError(tr("invalidExtension"))
            return nil
        }
        return normalized
    }

    private func normalizedCustomFileExtension(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = trimmed.drop { $0 == "." }
        let lowered = String(withoutLeadingDots).lowercased()
        guard !lowered.isEmpty, lowered.count <= 24 else { return nil }

        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_+"))
        guard lowered.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            return nil
        }
        return lowered
    }

    private func chooseSaveURLWithAppleScript(defaultName: String, fallbackExtension: String) -> URL? {
        let script = """
        set chosenFile to choose file name with prompt "\(appleScriptEscaped(tr("saveAs")))" default name "\(appleScriptEscaped(defaultName))" default location (path to desktop folder)
        POSIX path of chosenFile
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        NSApp.activate(ignoringOtherApps: true)
        window?.level = .normal

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            window?.level = isPinned ? .floating : .normal
            showError(error.localizedDescription)
            return nil
        }

        window?.level = isPinned ? .floating : .normal
        window?.makeKeyAndOrderFront(nil)

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if errorOutput.localizedCaseInsensitiveContains("User canceled") {
                return nil
            }
            showError(errorOutput.isEmpty ? tr("saveAs") : errorOutput)
            return nil
        }

        guard !output.isEmpty else { return nil }
        var url = URL(fileURLWithPath: output)
        if url.pathExtension.isEmpty {
            url.appendPathExtension(fallbackExtension)
        }
        return url
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func printCurrentTextDocument() {
        guard let text = textView?.string, !text.isEmpty else {
            showError(tr("noText"))
            return
        }

        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let imageablePageBounds = printInfo.imageablePageBounds
        let pageWidth = max(320, imageablePageBounds.width)
        let pageHeight = max(480, imageablePageBounds.height)
        let inset = NSSize(width: 18, height: 18)

        let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        printView.isEditable = false
        printView.isSelectable = false
        printView.isRichText = false
        printView.drawsBackground = false
        printView.textContainerInset = inset
        printView.font = textView?.font ?? .systemFont(ofSize: fontSize)
        printView.textColor = .textColor
        printView.isHorizontallyResizable = false
        printView.isVerticallyResizable = true
        printView.textContainer?.widthTracksTextView = true
        printView.textContainer?.containerSize = NSSize(
            width: pageWidth - inset.width * 2,
            height: CGFloat.greatestFiniteMagnitude
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: printView.font ?? NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]
        printView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))

        if let layoutManager = printView.layoutManager, let textContainer = printView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            printView.setFrameSize(NSSize(
                width: pageWidth,
                height: max(pageHeight, ceil(usedRect.height + inset.height * 2))
            ))
        }

        let operation = NSPrintOperation(view: printView, printInfo: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.jobTitle = tr("windowTitle")
        _ = operation.run()
    }

    private func clearTemporaryText() {
        previousProcessedText = nil
        replaceEditorText("", actionName: tr("clear"))
        showTemporaryStatus(tr("clear"))
    }

    @objc private func togglePinnedFromMenu() {
        isPinned.toggle()
        window?.level = isPinned ? .floating : .normal
        keepOnTopMenuItem?.state = isPinned ? .on : .off
        savePreferences()
    }

    @objc private func toggleLineNumbersFromMenu() {
        showsLineNumbers.toggle()
        lineNumberRuler?.isHidden = !showsLineNumbers
        scrollLeadingWithLineNumbersConstraint?.isActive = showsLineNumbers
        scrollLeadingWithoutLineNumbersConstraint?.isActive = !showsLineNumbers
        updateLineNumberWidth()
        lineNumbersMenuItem?.state = showsLineNumbers ? .on : .off
        lineNumberRuler?.needsDisplay = true
        savePreferences()
        revealStatusTemporarily()
    }

    @objc private func toggleWordWrapFromMenu() {
        wrapsText.toggle()
        applyWordWrap()
        wordWrapMenuItem?.state = wrapsText ? .on : .off
        savePreferences()
    }

    @objc private func toggleStatsFromMenu() {
        showsStats.toggle()
        statsMenuItem?.state = showsStats ? .on : .off
        savePreferences()
        updateTextState()
        if showsStats {
            revealStatusTemporarily()
        } else {
            statusHideWorkItem?.cancel()
            statusOverlay?.alphaValue = 0
            statusOverlay?.isHidden = true
        }
    }

    private func runAppleIntelligence(actionName: String, instruction: String) {
        guard let input = editableTextScopeForTool() else { return }
        guard #available(macOS 26.0, *) else {
            showError(tr("aiVersion"))
            return
        }

        beginAsyncOperation("\(actionName)...")
        activeTask = Task { [input, instruction, actionName] in
            do {
                let result = try await appleIntelligenceTransform(text: input.text, instruction: instruction)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finishAsyncOperation()
                    self.showAIResultPreview(result, sourceRange: input.range, actionName: actionName)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finishAsyncOperation()
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func runSystemTranslation(actionName: String, targetLanguageCode: String, appendSourceText: Bool = false) {
        guard let text = editableTextForTool() else { return }
        guard #available(macOS 26.0, *) else {
            showError(tr("translateVersion"))
            return
        }
        if inferredSourceLanguageCode(for: text) == targetLanguageCode {
            showError(tr("alreadyTarget"))
            return
        }

        beginAsyncOperation("\(actionName)...")
        activeTask = Task { [text, targetLanguageCode, actionName, appendSourceText] in
            do {
                let translatedText = try await systemTranslate(text: text, targetLanguageCode: targetLanguageCode)
                let result = appendSourceText ? "\(text)\n\n---\n\n\(translatedText)" : translatedText
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finishAsyncOperation()
                    self.previousProcessedText = text
                    self.replaceEditorText(result, actionName: actionName)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.finishAsyncOperation()
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func editableTextForTool() -> String? {
        guard let text = textView?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            showError(tr("noText"))
            return nil
        }
        return text
    }

    private func editableTextScopeForTool() -> (text: String, range: NSRange)? {
        guard let textView else {
            showError(tr("noText"))
            return nil
        }

        let selectedRange = textView.selectedRange()
        if selectedRange.length > 0,
           let stringRange = Range(selectedRange, in: textView.string) {
            let selectedText = String(textView.string[stringRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectedText.isEmpty {
                return (selectedText, selectedRange)
            }
        }

        let fullText = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            showError(tr("noText"))
            return nil
        }
        return (fullText, NSRange(location: 0, length: (textView.string as NSString).length))
    }

    private func askForCustomPrompt() -> String? {
        let alert = NSAlert()
        alert.messageText = tr("customPrompt")
        alert.informativeText = tr("customPromptMessage")
        alert.addButton(withTitle: tr("continue"))
        alert.addButton(withTitle: tr("cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        field.placeholderString = tr("customPromptPlaceholder")
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private func showAIResultPreview(_ result: String, sourceRange: NSRange, actionName: String) {
        let alert = NSAlert()
        alert.messageText = actionName
        alert.informativeText = tr("aiResult")
        alert.addButton(withTitle: tr("copyResult"))
        alert.addButton(withTitle: tr("appendResult"))
        alert.addButton(withTitle: tr("replaceOriginal"))
        alert.addButton(withTitle: tr("cancel"))

        let previewScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
        previewScroll.borderType = .noBorder
        previewScroll.hasVerticalScroller = true
        previewScroll.drawsBackground = false

        let preview = NSTextView(frame: previewScroll.bounds)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .systemFont(ofSize: 14)
        preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.backgroundColor = .clear
        preview.string = result
        previewScroll.documentView = preview
        alert.accessoryView = previewScroll

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(result, forType: .string)
            showTemporaryStatus(tr("copied"))
        case .alertSecondButtonReturn:
            appendEditorText(result, actionName: actionName)
        case .alertThirdButtonReturn:
            replaceEditorText(in: sourceRange, with: result, actionName: actionName)
        default:
            break
        }
    }

    private func beginAsyncOperation(_ status: String) {
        isAsyncOperationRunning = true
        statsLabel?.stringValue = status
        cursorLabel?.stringValue = ""
        revealStatusTemporarily(hideAfter: 60)
        progressHost?.isHidden = false
    }

    private func finishAsyncOperation() {
        isAsyncOperationRunning = false
        activeTask = nil
        progressHost?.isHidden = true
        updateTextState()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("ok"))
        alert.runModal()
    }

    func decreaseFontSize() {
        setFontSize(fontSize - 1)
    }

    func increaseFontSize() {
        setFontSize(fontSize + 1)
    }

    func resetFontSize() {
        setFontSize(defaultFontSize)
    }

    @objc private func decreaseFontSizeFromMenu() {
        decreaseFontSize()
    }

    @objc private func increaseFontSizeFromMenu() {
        increaseFontSize()
    }

    @objc private func resetFontSizeFromMenu() {
        resetFontSize()
    }

    private func setFontSize(_ newSize: CGFloat) {
        fontSize = min(maximumFontSize, max(minimumFontSize, newSize))
        textView?.font = .systemFont(ofSize: fontSize)
        lineNumberRuler?.updateRuleThickness()
        updateLineNumberWidth()
        lineNumberRuler?.needsDisplay = true
        savePreferences()
        updateTextState()
        revealStatusTemporarily()
    }

    private func applyWordWrap() {
        guard let textView, let scrollView else { return }
        textView.isHorizontallyResizable = !wrapsText
        textView.autoresizingMask = wrapsText ? [.width] : [.width, .height]
        textView.textContainer?.widthTracksTextView = wrapsText
        textView.textContainer?.containerSize = NSSize(
            width: wrapsText ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasHorizontalScroller = !wrapsText
        textView.needsDisplay = true
        revealStatusTemporarily()
    }

    private func showTemporaryStatus(_ message: String) {
        guard !isAsyncOperationRunning else { return }
        statusRestoreWorkItem?.cancel()
        statsLabel?.stringValue = message
        cursorLabel?.stringValue = ""
        revealStatusTemporarily(hideAfter: 1.6)
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateTextState()
        }
        statusRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: workItem)
    }

    private func applyProcessing(_ transform: (String) -> String) {
        guard let textView else { return }
        let oldText = textView.string
        let newText = transform(oldText)
        guard oldText != newText else { return }
        previousProcessedText = oldText
        replaceEditorText(newText, actionName: tr("process"))
        revealStatusTemporarily()
    }

    private func replaceEditorText(_ newText: String, actionName: String, registerUndo: Bool = true) {
        guard let textView else { return }
        let oldText = textView.string
        guard oldText != newText else {
            updateTextState()
            return
        }

        if registerUndo, let undoManager = textView.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceEditorText(oldText, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }

        isProgrammaticTextChange = true
        textView.string = newText
        isProgrammaticTextChange = false
        textView.needsDisplay = true
        lineNumberRuler?.updateRuleThickness()
        lineNumberRuler?.needsDisplay = true
        updateTextState()
    }

    private func appendEditorText(_ textToAppend: String, actionName: String) {
        guard let textView else { return }
        let separator = textView.string.isEmpty ? "" : "\n\n"
        replaceEditorText(textView.string + separator + textToAppend, actionName: actionName)
    }

    private func replaceEditorText(in range: NSRange, with replacement: String, actionName: String) {
        guard let textView else { return }
        let text = textView.string as NSString
        let boundedRange: NSRange
        if range.location != NSNotFound, range.location <= text.length {
            boundedRange = NSRange(location: range.location, length: min(range.length, text.length - range.location))
        } else {
            boundedRange = NSRange(location: 0, length: text.length)
        }
        let newText = text.replacingCharacters(in: boundedRange, with: replacement)
        replaceEditorText(newText, actionName: actionName)
    }

    private func updateTextState() {
        guard let textView else { return }
        guard !isAsyncOperationRunning else { return }
        let text = textView.string
        let characterCount = text.count
        let wordCount = englishWordCount(in: text)
        let lineCount = text.isEmpty ? 0 : normalizedLineEndings(text).components(separatedBy: "\n").count

        var parts = [
            "\(decimal(characterCount)) \(tr("chars"))",
            "\(decimal(wordCount)) \(tr("words"))",
            "\(decimal(lineCount)) \(tr("lines"))"
        ]

        let selectedText = textView.selectedText()
        if !selectedText.isEmpty {
            parts.append("\(tr("selected")) \(decimal(selectedText.count)) \(tr("chars"))")
        }

        statsLabel?.stringValue = parts.joined(separator: " · ")
        fontLabel?.stringValue = "· \(Int(fontSize)) pt"
        cursorLabel?.stringValue = cursorPositionText()
        statusOverlay?.isHidden = !showsStats
        saveAsMenuItem?.isEnabled = !text.isEmpty
        printMenuItem?.isEnabled = !text.isEmpty
        copyAllMenuItem?.isEnabled = !text.isEmpty
        clearTextMenuItem?.isEnabled = !text.isEmpty
        textView.needsDisplay = true
    }

    private func cursorPositionText() -> String {
        guard let textView else { return "" }
        let nsText = textView.string as NSString
        let location = min(textView.selectedRange().location, nsText.length)
        let prefix = nsText.substring(to: location)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let column = (prefix.components(separatedBy: "\n").last?.count ?? 0) + 1
        switch language {
        case .english:
            return "Ln \(line), Col \(column)"
        case .chinese:
            return "第 \(line) 行，第 \(column) 列"
        }
    }

    private func revealStatusTemporarily(hideAfter delay: TimeInterval = 2.1) {
        guard showsStats, let statusOverlay else { return }
        statusHideWorkItem?.cancel()
        statusOverlay.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            statusOverlay.animator().alphaValue = 0.86
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideStatusOverlay()
        }
        statusHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hideStatusOverlay() {
        guard showsStats, let statusOverlay else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            statusOverlay.animator().alphaValue = 0
        }
    }

    private func updateLineNumberWidth() {
        guard let lineNumberRuler else { return }
        lineNumberWidthConstraint?.constant = showsLineNumbers ? lineNumberRuler.ruleThickness : 0
    }

    private func destroy(closeWindow: Bool, terminateApp: Bool) {
        guard !isDestroying else { return }
        isDestroying = true

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        activeTask?.cancel()
        activeTask = nil
        statusRestoreWorkItem?.cancel()
        statusRestoreWorkItem = nil
        statusHideWorkItem?.cancel()
        statusHideWorkItem = nil

        textView?.string = ""
        textView?.undoManager?.removeAllActions()
        textView?.owner = nil
        textView?.delegate = nil
        textView?.removeFromSuperview()
        scrollView?.documentView = nil
        scrollView?.removeFromSuperview()
        rootView?.removeFromSuperview()

        let windowToClose = window
        windowToClose?.delegate = nil

        textView = nil
        lineNumberRuler = nil
        lineNumberWidthConstraint = nil
        scrollLeadingWithLineNumbersConstraint = nil
        scrollLeadingWithoutLineNumbersConstraint = nil
        scrollView = nil
        statusOverlay = nil
        statusBar = nil
        statsLabel = nil
        fontLabel = nil
        cursorLabel = nil
        progressHost = nil
        undoProcessItem = nil
        saveAsMenuItem = nil
        printMenuItem = nil
        copyAllMenuItem = nil
        clearTextMenuItem = nil
        keepOnTopMenuItem = nil
        lineNumbersMenuItem = nil
        wordWrapMenuItem = nil
        statsMenuItem = nil
        rootView = nil
        window = nil
        previousProcessedText = nil

        if closeWindow {
            windowToClose?.close()
        }

        if terminateApp {
            NSApp.terminate(nil)
        }
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.handleToolShortcut(event) {
                return nil
            }

            if self.shouldDestroy(for: event) {
                self.destroy(closeWindow: true, terminateApp: true)
                return nil
            }

            if self.shouldShowFindBar(for: event), let textView = self.textView {
                self.window?.makeFirstResponder(textView)
                textView.showFindInterface()
                return nil
            }

            if self.handleFontShortcut(event) {
                return nil
            }

            return event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.locationInWindow.y <= 58 {
                self.revealStatusTemporarily()
            }
            return event
        }
    }

    private func installScrollObserver() {
        guard let scrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.lineNumberRuler?.needsDisplay = true
            self?.revealStatusTemporarily()
        }
    }

    @discardableResult
    func handleEscapeKey() -> Bool {
        if closeFindBarIfNeeded() {
            return true
        }
        destroy(closeWindow: true, terminateApp: true)
        return true
    }

    private func handleToolShortcut(_ event: NSEvent) -> Bool {
        let modifiers = normalizedModifierFlags(from: event)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if modifiers == [.command, .shift], key == "r" {
            rereadClipboard(skipConfirm: false)
            return true
        }

        if modifiers == [.command, .shift], key == "c" {
            copyAllCurrentText()
            return true
        }

        if modifiers == [.command, .shift], key == "s" {
            saveCurrentTextAsFile()
            return true
        }

        if modifiers == .command, key == "p" {
            printCurrentTextDocument()
            return true
        }

        if modifiers == [.command, .shift], event.keyCode == 51 {
            clearTemporaryText()
            return true
        }

        return false
    }

    private func shouldDestroy(for event: NSEvent) -> Bool {
        let modifiers = normalizedModifierFlags(from: event)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command && key == "w" {
            return true
        }

        if event.keyCode == 53 {
            return !closeFindBarIfNeeded()
        }

        return false
    }

    private func closeFindBarIfNeeded() -> Bool {
        guard let scrollView, scrollView.isFindBarVisible else {
            return false
        }
        scrollView.isFindBarVisible = false
        return true
    }

    private func shouldShowFindBar(for event: NSEvent) -> Bool {
        let modifiers = normalizedModifierFlags(from: event)
        let key = event.charactersIgnoringModifiers?.lowercased()
        return modifiers == .command && key == "f"
    }

    private func handleFontShortcut(_ event: NSEvent) -> Bool {
        let modifiers = normalizedModifierFlags(from: event)
        guard modifiers == .command else { return false }

        switch event.charactersIgnoringModifiers {
        case "-", "_":
            decreaseFontSize()
            return true
        case "+", "=":
            increaseFontSize()
            return true
        case "0":
            resetFontSize()
            return true
        default:
            return false
        }
    }

    private func centeredFrameOnMouseScreen(size: NSSize) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first

        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )

        return NSRect(origin: origin, size: size)
    }
}

private final class ClipboardTextView: NSTextView {
    weak var owner: TemporaryClipboardApp?
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 17),
            .paragraphStyle: paragraph
        ]

        let visible = visibleRect
        let size = (placeholder as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        (placeholder as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            owner?.handleEscapeKey()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = normalizedModifierFlags(from: event)
        let key = event.charactersIgnoringModifiers?.lowercased()

        guard modifiers.contains(.command), let key else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "w" where modifiers == .command:
            owner?.destroyFromShortcut()
            return true
        case "a" where modifiers == .command:
            selectAll(nil)
            return true
        case "c" where modifiers == .command:
            copy(nil)
            return true
        case "v" where modifiers == .command:
            paste(nil)
            return true
        case "x" where modifiers == .command:
            cut(nil)
            return true
        case "z" where modifiers == .command:
            undoManager?.undo()
            return true
        case "z" where modifiers == [.command, .shift]:
            undoManager?.redo()
            return true
        case "f" where modifiers == .command:
            showFindInterface()
            return true
        case "s" where modifiers == [.command, .shift]:
            owner?.saveCurrentTextAsFile()
            return true
        case "p" where modifiers == .command:
            owner?.printCurrentTextDocument()
            return true
        case "-", "_":
            owner?.decreaseFontSize()
            return true
        case "+", "=":
            owner?.increaseFontSize()
            return true
        case "0":
            owner?.resetFontSize()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    func showFindInterface() {
        let sender = NSMenuItem()
        sender.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(sender)
    }

    func selectedText() -> String {
        let range = selectedRange()
        guard range.length > 0, let stringRange = Range(range, in: string) else {
            return ""
        }
        return String(string[stringRange])
    }
}

let app = NSApplication.shared
let delegate = TemporaryClipboardApp(initialText: readLaunchText())
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
