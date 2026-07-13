//
//  HistorySearchFieldView.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Codex on 2026/07/12.
//
//  Copyright © 2015-2026 Clipy Project.
//

import AppKit
import Carbon.HIToolbox

/// Delegate for user interaction inside the history search field.
///
/// The controller owning the search field adopts this to react to text
/// changes and keyboard navigation while an `NSMenu` is tracking.
protocol HistorySearchFieldViewDelegate: AnyObject {
    /// The query text changed (including when cleared by the cancel button).
    func historySearchFieldView(_ view: HistorySearchFieldView, didChangeQuery query: String)
    /// Return was pressed while the field had focus.
    func historySearchFieldViewDidCommit(_ view: HistorySearchFieldView)
    /// Down arrow was pressed; focus should move into the result list.
    func historySearchFieldViewDidRequestMoveToResults(_ view: HistorySearchFieldView)
    /// The cancel button cleared the field; History should be restored immediately.
    func historySearchFieldViewDidCancel(_ view: HistorySearchFieldView)
}

/// A minimal `NSSearchField` host designed to live inside an `NSMenuItem.view`.
///
/// The view is intentionally self-contained so its focus and editing behavior
/// can be exercised in isolation (Milestone 0 feasibility gate) before the
/// surrounding menu session machinery is built.
final class HistorySearchFieldView: NSView, NSSearchFieldDelegate {

    // MARK: - Properties
    /// Minimum width so the field never collapses inside a narrow menu.
    static let preferredWidth: CGFloat = 260
    static let preferredHeight: CGFloat = 28
    private static let horizontalInset: CGFloat = 20
    private static let verticalInset: CGFloat = 4

    let searchField = NSSearchField()
    weak var delegate: HistorySearchFieldViewDelegate?
    private let currentKeyboardInputSourceIdentifier: () -> NSTextInputSourceIdentifier?
    private let caretView = HistorySearchCaretView()
    private var keyboardSelectionObserver: NSObjectProtocol?
    private var textSelectionObserver: NSObjectProtocol?
    private var caretBlinkTimer: Timer?
    private var caretIsVisible = true

    /// Whether the field editor currently holds uncommitted marked text (an
    /// in-progress IME composition). Used to avoid announcing intermediate
    /// composition states to VoiceOver.
    var hasMarkedText: Bool {
        (searchField.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }

    /// Current, untrimmed query text.
    var query: String {
        get { searchField.stringValue }
        set {
            guard searchField.stringValue != newValue else { return }
            searchField.stringValue = newValue
        }
    }

    // MARK: - Initialize
    init(
        currentKeyboardInputSourceIdentifier: @escaping () -> NSTextInputSourceIdentifier? =
            HistorySearchFieldView.currentKeyboardInputSourceIdentifier
    ) {
        self.currentKeyboardInputSourceIdentifier = currentKeyboardInputSourceIdentifier
        super.init(frame: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: Self.preferredHeight))
        setupSearchField()
        observeKeyboardSelectionChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyboardSelectionObserver {
            NotificationCenter.default.removeObserver(keyboardSelectionObserver)
        }
        if let textSelectionObserver {
            NotificationCenter.default.removeObserver(textSelectionObserver)
        }
        caretBlinkTimer?.invalidate()
    }

    private func setupSearchField() {
        autoresizingMask = [.width]
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.placeholderString = String(localized: "Search History")
        searchField.setAccessibilityLabel(String(localized: "Search History"))
        searchField.focusRingType = .none
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = self
        (searchField.cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(cancelButtonClicked(_:))
        addSubview(searchField)
        setupCaretView()
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            searchField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.preferredWidth)
        ])
    }

    // MARK: - Focus
    /// Makes the search field first responder without activating the app.
    ///
    /// Returns whether the field editor was successfully installed.
    @discardableResult
    func focusSearchField() -> Bool {
        guard let window = searchField.window else { return false }
        let didFocus = window.makeFirstResponder(searchField)
        if didFocus {
            searchField.currentEditor()?.selectedRange = NSRange(location: 0, length: searchField.stringValue.count)
            applyActiveFieldEditorAppearance()
            showCustomCaret()
        }
        return didFocus
    }

    /// Clears the query without notifying the delegate.
    func reset() {
        searchField.stringValue = ""
        searchField.abortEditing()
        hideCustomCaret()
    }

    @discardableResult
    func refreshInputContextForCurrentKeyboardSource() -> Bool {
        guard let textView = searchField.currentEditor() as? NSTextView,
              let inputContext = textView.inputContext else {
            return false
        }

        applyActiveFieldEditorAppearance(to: textView)
        if let inputSourceIdentifier = currentKeyboardInputSourceIdentifier() {
            inputContext.selectedKeyboardInputSource = inputSourceIdentifier
        }
        inputContext.invalidateCharacterCoordinates()
        return true
    }

    // MARK: - Actions
    @objc private func cancelButtonClicked(_ sender: Any?) {
        searchField.stringValue = ""
        showCustomCaret()
        delegate?.historySearchFieldViewDidCancel(self)
    }

    // MARK: - NSSearchFieldDelegate
    func controlTextDidBeginEditing(_ obj: Notification) {
        applyActiveFieldEditorAppearance()
        showCustomCaret()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyActiveFieldEditorAppearance()
        showCustomCaret()
        delegate?.historySearchFieldView(self, didChangeQuery: searchField.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        hideCustomCaret()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.historySearchFieldViewDidCommit(self)
            return true
        case #selector(NSResponder.moveDown(_:)):
            delegate?.historySearchFieldViewDidRequestMoveToResults(self)
            return true
        default:
            return false
        }
    }

    override func layout() {
        super.layout()
        if !caretView.isHidden {
            updateCustomCaretFrame()
        }
    }
}

private extension HistorySearchFieldView {
    static let caretBlinkInterval: TimeInterval = 0.53
    static let caretWidth: CGFloat = 2
    static let caretHeight: CGFloat = 18

    var activeFieldEditorInsertionPointColor: NSColor {
        if searchField.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return .white
        }
        return .black
    }

    func applyActiveFieldEditorAppearance() {
        guard let textView = searchField.currentEditor() as? NSTextView else { return }
        applyActiveFieldEditorAppearance(to: textView)
    }

    func applyActiveFieldEditorAppearance(to textView: NSTextView) {
        textView.insertionPointColor = activeFieldEditorInsertionPointColor
        textView.updateInsertionPointStateAndRestartTimer(true)
    }

    func setupCaretView() {
        caretView.wantsLayer = true
        caretView.layer?.cornerRadius = Self.caretWidth / 2
        caretView.isHidden = true
        addSubview(caretView)
    }

    func showCustomCaret() {
        caretIsVisible = true
        updateCustomCaretFrame()
        startCaretBlinking()
    }

    func hideCustomCaret() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        caretIsVisible = false
        caretView.isHidden = true
    }

    func startCaretBlinking() {
        guard caretBlinkTimer == nil else { return }
        let timer = Timer(timeInterval: Self.caretBlinkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretIsVisible.toggle()
            self.updateCustomCaretFrame()
        }
        caretBlinkTimer = timer
        RunLoop.current.add(timer, forMode: .eventTracking)
        RunLoop.current.add(timer, forMode: .default)
    }

    func updateCustomCaretFrame() {
        guard let textView = searchField.currentEditor() as? NSTextView else {
            caretView.isHidden = true
            return
        }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else {
            caretView.isHidden = true
            return
        }

        caretView.layer?.backgroundColor = activeFieldEditorInsertionPointColor.cgColor
        caretView.frame = customCaretFrame(for: textView, selectedRange: selectedRange)
        caretView.isHidden = !caretIsVisible
    }

    func customCaretFrame(for textView: NSTextView, selectedRange: NSRange) -> NSRect {
        let range = NSRange(location: selectedRange.location, length: 0)
        let editorRect = textView.firstRect(forCharacterRange: range, actualRange: nil)

        if !editorRect.isEmpty, let window = searchField.window {
            let rectInWindow = window.convertFromScreen(editorRect)
            let rectInView = convert(rectInWindow, from: nil)
            return normalizedCaretFrame(atX: rectInView.minX)
        }

        return fallbackCustomCaretFrame(for: textView, selectedRange: selectedRange)
    }

    func fallbackCustomCaretFrame(for textView: NSTextView, selectedRange: NSRange) -> NSRect {
        let textRect = searchField.cell?.titleRect(forBounds: searchField.bounds)
            ?? searchField.bounds.insetBy(dx: 30, dy: 5)
        let safeLocation = min(max(selectedRange.location, 0), (searchField.stringValue as NSString).length)
        let prefix = (searchField.stringValue as NSString).substring(to: safeLocation)
        let font = textView.font ?? searchField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let prefixWidth = (prefix as NSString).size(withAttributes: [.font: font]).width
        let caretPointInField = NSPoint(x: textRect.minX + prefixWidth, y: textRect.midY)
        let caretPoint = convert(caretPointInField, from: searchField)
        return normalizedCaretFrame(atX: caretPoint.x)
    }

    func normalizedCaretFrame(atX horizontalPosition: CGFloat) -> NSRect {
        let minX = searchField.frame.minX + 30
        let maxX = searchField.frame.maxX - 30
        let clampedX = min(max(horizontalPosition, minX), maxX)
        let height = min(Self.caretHeight, max(1, searchField.frame.height - 8))
        return NSRect(
            x: roundedForBackingScale(clampedX),
            y: roundedForBackingScale(searchField.frame.midY - height / 2),
            width: Self.caretWidth,
            height: height
        )
    }

    func roundedForBackingScale(_ value: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded() / scale
    }

    func observeKeyboardSelectionChanges() {
        keyboardSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                self.refreshInputContextForCurrentKeyboardSource()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.refreshInputContextForCurrentKeyboardSource()
                }
            }
        }

        textSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let textView = notification.object as? NSTextView else {
                return
            }
            let currentEditor = self.searchField.currentEditor() as? NSTextView
            guard textView === currentEditor else {
                return
            }
            if Thread.isMainThread {
                self.showCustomCaret()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.showCustomCaret()
                }
            }
        }
    }

    static func currentKeyboardInputSourceIdentifier() -> NSTextInputSourceIdentifier? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawIdentifier = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }

        return Unmanaged<CFString>
            .fromOpaque(rawIdentifier)
            .takeUnretainedValue() as String
    }
}

private final class HistorySearchCaretView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
