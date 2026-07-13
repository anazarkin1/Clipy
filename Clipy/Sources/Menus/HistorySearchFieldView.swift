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
    private var keyboardSelectionObserver: NSObjectProtocol?

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
        }
        return didFocus
    }

    /// Clears the query without notifying the delegate.
    func reset() {
        searchField.stringValue = ""
        searchField.abortEditing()
    }

    @discardableResult
    func refreshInputContextForCurrentKeyboardSource() -> Bool {
        guard let textView = searchField.currentEditor() as? NSTextView,
              let inputContext = textView.inputContext else {
            return false
        }

        if let inputSourceIdentifier = currentKeyboardInputSourceIdentifier() {
            inputContext.selectedKeyboardInputSource = inputSourceIdentifier
        }
        inputContext.invalidateCharacterCoordinates()
        return true
    }

    // MARK: - Actions
    @objc private func cancelButtonClicked(_ sender: Any?) {
        searchField.stringValue = ""
        delegate?.historySearchFieldViewDidCancel(self)
    }

    // MARK: - NSSearchFieldDelegate
    func controlTextDidChange(_ obj: Notification) {
        delegate?.historySearchFieldView(self, didChangeQuery: searchField.stringValue)
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
}

private extension HistorySearchFieldView {
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
