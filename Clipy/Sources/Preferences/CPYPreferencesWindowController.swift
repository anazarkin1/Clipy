//
//  CPYPreferencesWindowController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/02/25.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

final class CPYPreferencesWindowController: NSWindowController {

    // MARK: - Properties
    static let sharedController = CPYPreferencesWindowController(windowNibName: "CPYPreferencesWindowController")
    @IBOutlet private weak var toolBar: NSView!
    // ImageViews
    @IBOutlet private weak var generalImageView: NSImageView!
    @IBOutlet private weak var menuImageView: NSImageView!
    @IBOutlet private weak var typeImageView: NSImageView!
    @IBOutlet private weak var excludeImageView: NSImageView!
    @IBOutlet private weak var shortcutsImageView: NSImageView!
    @IBOutlet private weak var updatesImageView: NSImageView!
    @IBOutlet private weak var betaImageView: NSImageView!
    // Labels
    @IBOutlet private weak var generalTextField: NSTextField!
    @IBOutlet private weak var menuTextField: NSTextField!
    @IBOutlet private weak var typeTextField: NSTextField!
    @IBOutlet private weak var excludeTextField: NSTextField!
    @IBOutlet private weak var shortcutsTextField: NSTextField!
    @IBOutlet private weak var updatesTextField: NSTextField!
    @IBOutlet private weak var betaTextField: NSTextField!
    private weak var securityTextField: NSTextField?
    private var securityToolbarContainer: NSView?
    // Buttons
    @IBOutlet private weak var generalButton: NSButton!
    @IBOutlet private weak var menuButton: NSButton!
    @IBOutlet private weak var typeButton: NSButton!
    @IBOutlet private weak var excludeButton: NSButton!
    @IBOutlet private weak var shortcutsButton: NSButton!
    @IBOutlet private weak var updatesButton: NSButton!
    @IBOutlet private weak var betaButton: NSButton!
    private weak var securityButton: NSButton?
    // ViewController
    private let viewController = [NSViewController(nibName: "CPYGeneralPreferenceViewController", bundle: nil),
                                  NSViewController(nibName: "CPYMenuPreferenceViewController", bundle: nil),
                                  CPYTypePreferenceViewController(nibName: "CPYTypePreferenceViewController", bundle: nil),
                                  CPYExcludeAppPreferenceViewController(nibName: "CPYExcludeAppPreferenceViewController", bundle: nil),
                                  CPYShortcutsPreferenceViewController(nibName: "CPYShortcutsPreferenceViewController", bundle: nil),
                                  CPYUpdatesPreferenceViewController(nibName: "CPYUpdatesPreferenceViewController", bundle: nil),
                                  CPYBetaPreferenceViewController(nibName: "CPYBetaPreferenceViewController", bundle: nil),
                                  SecurityPreferenceHostingController()]

    // MARK: - Window Life Cycle
    override func windowDidLoad() {
        super.windowDidLoad()
        // Temporarily disable Dark Mode until this window is migrated to SwiftUI.
        self.window?.appearance = NSAppearance(named: .aqua)
        self.window?.backgroundColor = NSColor(white: 0.99, alpha: 1)
        self.window?.titlebarAppearsTransparent = true
        addSecurityToolbarItem()
        toolBarItemTapped(generalButton)
        generalButton.sendAction(on: .leftMouseDown)
        menuButton.sendAction(on: .leftMouseDown)
        typeButton.sendAction(on: .leftMouseDown)
        excludeButton.sendAction(on: .leftMouseDown)
        shortcutsButton.sendAction(on: .leftMouseDown)
        updatesButton.sendAction(on: .leftMouseDown)
        betaButton.sendAction(on: .leftMouseDown)
        securityButton?.sendAction(on: .leftMouseDown)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}

// MARK: - IBActions
extension CPYPreferencesWindowController {
    @IBAction private func toolBarItemTapped(_ sender: NSButton) {
        selectedTab(sender.tag)
        switchView(sender.tag)
    }
}

// MARK: - NSWindow Delegate
extension CPYPreferencesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = window, !window.makeFirstResponder(window) {
            window.endEditing(for: nil)
        }
        NSApp.deactivate()
    }
}

// MARK: - Layout
private extension CPYPreferencesWindowController {
    func resetImages() {
        generalImageView.image = NSImage(resource: .prefGeneral)
        menuImageView.image = NSImage(resource: .prefMenu)
        typeImageView.image = NSImage(resource: .prefType)
        excludeImageView.image = NSImage(resource: .prefExcluded)
        shortcutsImageView.image = NSImage(resource: .prefShortcut)
        updatesImageView.image = NSImage(resource: .prefUpdate)
        betaImageView.image = NSImage(resource: .prefBeta)

        generalTextField.textColor = NSColor(resource: .tabTitle)
        menuTextField.textColor = NSColor(resource: .tabTitle)
        typeTextField.textColor = NSColor(resource: .tabTitle)
        excludeTextField.textColor = NSColor(resource: .tabTitle)
        shortcutsTextField.textColor = NSColor(resource: .tabTitle)
        updatesTextField.textColor = NSColor(resource: .tabTitle)
        betaTextField.textColor = NSColor(resource: .tabTitle)
        securityTextField?.textColor = NSColor(resource: .tabTitle)
    }

    func selectedTab(_ index: Int) {
        resetImages()

        switch index {
        case 0:
            generalImageView.image = NSImage(resource: .prefGeneralOn)
            generalTextField.textColor = NSColor(resource: .clipy)
        case 1:
            menuImageView.image = NSImage(resource: .prefMenuOn)
            menuTextField.textColor = NSColor(resource: .clipy)
        case 2:
            typeImageView.image = NSImage(resource: .prefTypeOn)
            typeTextField.textColor = NSColor(resource: .clipy)
        case 3:
            excludeImageView.image = NSImage(resource: .prefExcludedOn)
            excludeTextField.textColor = NSColor(resource: .clipy)
        case 4:
            shortcutsImageView.image = NSImage(resource: .prefShortcutOn)
            shortcutsTextField.textColor = NSColor(resource: .clipy)
        case 5:
            updatesImageView.image = NSImage(resource: .prefUpdateOn)
            updatesTextField.textColor = NSColor(resource: .clipy)
        case 6:
            betaImageView.image = NSImage(resource: .prefBetaOn)
            betaTextField.textColor = NSColor(resource: .clipy)
        case 7:
            securityTextField?.textColor = NSColor(resource: .clipy)
        default: break
        }
    }

    func addSecurityToolbarItem() {
        let horizontalOffset = betaButton.superview?.frame.maxX ?? 359
        let container = NSView(frame: NSRect(x: horizontalOffset, y: 0, width: 70, height: 56))
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.maxXMargin]

        let label = NSTextField(labelWithString: String(localized: "Security"))
        label.frame = NSRect(x: 3, y: 8, width: 64, height: 12)
        label.alignment = .center
        label.font = NSFont(name: "HiraKakuProN-W6", size: 9) ?? NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor(resource: .tabTitle)

        let button = NSButton(frame: container.bounds)
        button.isBordered = false
        button.tag = 7
        button.target = self
        button.action = #selector(toolBarItemTapped(_:))
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel(String(localized: "Security Preferences"))

        container.addSubview(label)
        container.addSubview(button)
        toolBar.addSubview(container)
        securityToolbarContainer = container
        securityTextField = label
        securityButton = button
    }

    func switchView(_ index: Int) {
        let newView = viewController[index].view
        let contentSize = preferredContentSize(for: newView, controller: viewController[index])
        newView.frame = NSRect(origin: .zero, size: contentSize)
        // Remove current views without toolbar
        window?.contentView?.subviews.forEach { view in
            if view != toolBar {
                view.removeFromSuperview()
            }
        }
        // Resize view
        let frame = window!.frame
        var newFrame = window!.frameRect(forContentRect: newView.frame)
        newFrame.origin = frame.origin
        newFrame.origin.y += frame.height - newFrame.height - toolBar.frame.height
        newFrame.size.height += toolBar.frame.height
        window?.setFrame(newFrame, display: true)
        window?.contentView?.addSubview(newView)
    }

    func preferredContentSize(for view: NSView, controller: NSViewController) -> NSSize {
        if view.frame.width > 0, view.frame.height > 0 {
            return view.frame.size
        }

        let fittingSize = view.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            return fittingSize
        }

        if controller.preferredContentSize.width > 0, controller.preferredContentSize.height > 0 {
            return controller.preferredContentSize
        }

        return NSSize(width: 480, height: 318)
    }
}
