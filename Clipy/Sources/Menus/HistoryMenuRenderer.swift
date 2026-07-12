//
//  HistoryMenuRenderer.swift
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

/// Deterministic rendering of history menu items from explicit inputs.
///
/// Both the unfiltered History list and filtered Search Results go through this
/// single path so their numbering, shortcuts, grouping, thumbnails, and actions
/// cannot diverge. The renderer reads no UserDefaults and fetches no data — all
/// presentation values arrive via `HistoryMenuPresentation`.
struct HistoryMenuRenderer {
    let presentation: HistoryMenuPresentation
    /// Action invoked when a history item is selected (e.g.
    /// `AppDelegate.selectClipMenuItem(_:)`).
    let action: Selector
    /// Optional explicit target. `nil` preserves the historical responder-chain
    /// routing to `AppDelegate`.
    let target: AnyObject?
    /// Folder icon used for overflow submenus, or `nil` when icons are hidden.
    let folderIcon: NSImage?

    init(
        presentation: HistoryMenuPresentation,
        action: Selector,
        target: AnyObject? = nil,
        folderIcon: NSImage? = nil
    ) {
        self.presentation = presentation
        self.action = action
        self.target = target
        self.folderIcon = folderIcon
    }

    /// Builds the top-level history items (inline entries plus overflow folder
    /// items whose submenus are fully populated), preserving the input order.
    func makeHistoryItems(_ details: [PasteboardHistoryDetail]) -> [NSMenuItem] {
        let placeInLine = presentation.numberOfItemsPlaceInline
        let placeInsideFolder = presentation.numberOfItemsPlaceInsideFolder
        let firstIndex = presentation.firstListNumber
        let currentSize = details.count

        var topItems: [NSMenuItem] = []
        var currentFolderSubmenu: NSMenu?
        var listNumber = firstIndex
        var subMenuBoundary = placeInLine

        for (i, detail) in details.enumerated() {
            if placeInLine < 1 || placeInLine - 1 < i {
                // Overflow folder placement.
                if i == subMenuBoundary {
                    let folderItem = makeFolderItem(
                        count: subMenuBoundary,
                        start: firstIndex,
                        end: currentSize,
                        numberOfItems: placeInsideFolder
                    )
                    topItems.append(folderItem)
                    currentFolderSubmenu = folderItem.submenu
                    listNumber = firstIndex
                }
                if let submenu = currentFolderSubmenu {
                    submenu.addItem(makeClipItem(detail, index: i, listNumber: listNumber))
                    listNumber += 1
                }
            } else {
                // Inline placement.
                topItems.append(makeClipItem(detail, index: i, listNumber: listNumber))
                listNumber += 1
            }

            if i + 1 == subMenuBoundary + placeInsideFolder {
                subMenuBoundary += placeInsideFolder
            }
        }
        return topItems
    }

    /// The single disabled, inert item shown when a query matches no history.
    func makeNoMatchesItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.target = nil
        item.representedObject = nil
        item.toolTip = nil
        item.submenu = nil
        return item
    }

    // MARK: - Item construction
    private func makeClipItem(_ detail: PasteboardHistoryDetail, index: Int, listNumber: Int) -> NSMenuItem {
        let history = detail.history

        var keyEquivalent = ""
        if presentation.addsNumericKeyEquivalents && index < presentation.maxKeyEquivalents {
            var shortCutNumber = index + presentation.firstListNumber
            if shortCutNumber == presentation.maxKeyEquivalents {
                shortCutNumber = 0
            }
            keyEquivalent = "\(shortCutNumber)"
        }

        let title = presentation.isMarkedWithNumbers
            ? "\(listNumber). \(history.typedTitle)"
            : history.typedTitle

        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.representedObject = history.id
        item.target = target
        item.toolTip = toolTip(for: history)

        if let image = thumbnailImage(for: detail) {
            item.image = image
        }
        return item
    }

    private func toolTip(for history: PasteboardHistory) -> String? {
        guard presentation.showsToolTip else { return nil }
        return String(history.title.prefix(presentation.maxLengthOfToolTip))
    }

    private func thumbnailImage(for detail: PasteboardHistoryDetail) -> NSImage? {
        guard presentation.showsImage || presentation.showsColorPreview,
              let thumbnailAsset = detail.thumbnailAsset,
              let image = NSImage(data: thumbnailAsset.data),
              (thumbnailAsset.kind == .image && presentation.showsImage)
                || (thumbnailAsset.kind == .colorCode && presentation.showsColorPreview)
        else {
            return nil
        }
        return image.aspectFitImage(CGFloat(presentation.thumbnailWidth), CGFloat(presentation.thumbnailHeight))
    }

    private func makeFolderItem(count: Int, start: Int, end: Int, numberOfItems: Int) -> NSMenuItem {
        var count = count
        if start == 0 {
            count -= 1
        }
        var lastNumber = count + numberOfItems
        if end < lastNumber {
            lastNumber = end
        }
        let title = "\(count + 1) - \(lastNumber)"

        let submenu = NSMenu(title: "")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.image = folderIcon
        return item
    }
}
