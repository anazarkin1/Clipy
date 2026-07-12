//
//  HistoryMenuRendererTests.swift
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
import Testing
@testable import Clipy

@MainActor
@Suite
struct HistoryMenuRendererTests {

    private let action = #selector(AppDelegate.selectClipMenuItem(_:))

    // MARK: - Fixtures
    private func presentation(
        firstListNumber: Int = 1,
        isMarkedWithNumbers: Bool = false,
        addsNumericKeyEquivalents: Bool = false,
        numberOfItemsPlaceInline: Int = 10,
        numberOfItemsPlaceInsideFolder: Int = 10,
        showsImage: Bool = false,
        showsColorPreview: Bool = false,
        showsToolTip: Bool = false,
        maxLengthOfToolTip: Int = 100
    ) -> HistoryMenuPresentation {
        HistoryMenuPresentation(
            firstListNumber: firstListNumber,
            isMarkedWithNumbers: isMarkedWithNumbers,
            addsNumericKeyEquivalents: addsNumericKeyEquivalents,
            numberOfItemsPlaceInline: numberOfItemsPlaceInline,
            numberOfItemsPlaceInsideFolder: numberOfItemsPlaceInsideFolder,
            showsImage: showsImage,
            showsColorPreview: showsColorPreview,
            showsFolderIcon: false,
            thumbnailWidth: 20,
            thumbnailHeight: 20,
            showsToolTip: showsToolTip,
            maxLengthOfToolTip: maxLengthOfToolTip
        )
    }

    private func detail(
        id: String,
        title: String,
        ocrText: String? = nil,
        types: [NSPasteboard.PasteboardType] = [.string],
        thumbnail: PasteboardHistoryThumbnailAsset? = nil
    ) -> PasteboardHistoryDetail {
        PasteboardHistoryDetail(
            history: PasteboardHistory(
                id: .init(rawValue: id),
                title: title,
                ocrText: ocrText,
                pasteboardTypes: types,
                createdAt: 1,
                updateAt: 1,
                deviceID: nil
            ),
            thumbnailAsset: thumbnail
        )
    }

    private func details(count: Int) -> [PasteboardHistoryDetail] {
        (0..<count).map { detail(id: "\($0)", title: "item\($0)") }
    }

    private func renderer(_ presentation: HistoryMenuPresentation, target: AnyObject? = nil, folderIcon: NSImage? = nil) -> HistoryMenuRenderer {
        HistoryMenuRenderer(presentation: presentation, action: action, target: target, folderIcon: folderIcon)
    }

    // MARK: - Numbering
    @Test
    func oneBasedNumberingMatchesPreference() {
        let items = renderer(presentation(firstListNumber: 1, isMarkedWithNumbers: true)).makeHistoryItems(details(count: 3))
        #expect(items.map(\.title) == ["1. item0", "2. item1", "3. item2"])
    }

    @Test
    func zeroBasedNumberingMatchesPreference() {
        let items = renderer(presentation(firstListNumber: 0, isMarkedWithNumbers: true)).makeHistoryItems(details(count: 3))
        #expect(items.map(\.title) == ["0. item0", "1. item1", "2. item2"])
    }

    @Test
    func numbersAreOmittedWhenNotMarked() {
        let items = renderer(presentation(isMarkedWithNumbers: false)).makeHistoryItems(details(count: 2))
        #expect(items.map(\.title) == ["item0", "item1"])
    }

    // MARK: - Numeric key equivalents
    @Test
    func numericKeyEquivalentsCoverFirstTenAndMapTenToZeroOneBased() {
        let items = renderer(presentation(firstListNumber: 1, addsNumericKeyEquivalents: true, numberOfItemsPlaceInline: 20))
            .makeHistoryItems(details(count: 11))
        #expect(items.prefix(10).map(\.keyEquivalent) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        #expect(items[10].keyEquivalent == "")
    }

    @Test
    func numericKeyEquivalentsZeroBased() {
        let items = renderer(presentation(firstListNumber: 0, addsNumericKeyEquivalents: true, numberOfItemsPlaceInline: 20))
            .makeHistoryItems(details(count: 11))
        #expect(items.prefix(10).map(\.keyEquivalent) == ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        #expect(items[10].keyEquivalent == "")
    }

    @Test
    func numericKeyEquivalentsDisabled() {
        let items = renderer(presentation(addsNumericKeyEquivalents: false)).makeHistoryItems(details(count: 3))
        #expect(items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    // MARK: - Grouping boundaries
    @Test
    func zeroItemsProduceNoRows() {
        #expect(renderer(presentation()).makeHistoryItems([]).isEmpty)
    }

    @Test
    func singleInlineItem() {
        let items = renderer(presentation(numberOfItemsPlaceInline: 10, numberOfItemsPlaceInsideFolder: 2)).makeHistoryItems(details(count: 1))
        #expect(items.count == 1)
        #expect(items[0].submenu == nil)
    }

    @Test
    func exactBoundaryHasNoFolders() {
        let items = renderer(presentation(numberOfItemsPlaceInline: 2, numberOfItemsPlaceInsideFolder: 2)).makeHistoryItems(details(count: 2))
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.submenu == nil })
    }

    @Test
    func boundaryPlusOneCreatesOneFolder() {
        let items = renderer(presentation(numberOfItemsPlaceInline: 2, numberOfItemsPlaceInsideFolder: 2)).makeHistoryItems(details(count: 3))
        #expect(items.count == 3) // 2 inline + 1 folder
        #expect(items[0].submenu == nil)
        #expect(items[1].submenu == nil)
        #expect(items[2].submenu?.items.count == 1)
    }

    @Test
    func partialLastFolderBoundariesAndTitles() {
        let items = renderer(presentation(firstListNumber: 1, numberOfItemsPlaceInline: 1, numberOfItemsPlaceInsideFolder: 2)).makeHistoryItems(details(count: 6))
        // 1 inline + 3 folders (2,2,1)
        #expect(items.count == 4)
        #expect(items[0].submenu == nil)
        let folders = items[1...]
        #expect(folders.map { $0.submenu?.items.count } == [2, 2, 1])
        #expect(folders.map(\.title) == ["2 - 3", "4 - 5", "6 - 6"])
    }

    @Test
    func allItemsInsideFoldersWhenInlineIsZero() {
        let items = renderer(presentation(firstListNumber: 1, numberOfItemsPlaceInline: 0, numberOfItemsPlaceInsideFolder: 2)).makeHistoryItems(details(count: 3))
        // 0 inline; folders of 2 -> folder(2) + folder(1)
        #expect(items.allSatisfy { $0.submenu != nil })
        #expect(items.map { $0.submenu?.items.count } == [2, 1])
    }

    // MARK: - Item attributes
    @Test
    func representedIdActionAndTargetArePreserved() {
        let target = NSObject()
        let items = renderer(presentation(), target: target).makeHistoryItems([detail(id: "abc", title: "hello")])
        #expect(items[0].representedObject as? PasteboardHistory.ID == .init(rawValue: "abc"))
        #expect(items[0].action == action)
        #expect(items[0].target as? NSObject === target)
    }

    @Test
    func nilTargetPreservesResponderChainRouting() {
        let items = renderer(presentation(), target: nil).makeHistoryItems([detail(id: "abc", title: "hello")])
        #expect(items[0].target == nil)
    }

    @Test
    func tooltipHonorsPresentation() {
        let long = String(repeating: "x", count: 500)
        let withTip = renderer(presentation(showsToolTip: true, maxLengthOfToolTip: 10)).makeHistoryItems([detail(id: "1", title: long)])
        #expect(withTip[0].toolTip == String(long.prefix(10)))

        let withoutTip = renderer(presentation(showsToolTip: false)).makeHistoryItems([detail(id: "1", title: long)])
        #expect(withoutTip[0].toolTip == nil)
    }

    @Test
    func imageThumbnailShownOnlyWhenEnabled() {
        let imageData = NSImage.create(with: .blue, size: NSSize(width: 10, height: 10)).tiffRepresentation!
        let thumb = PasteboardHistoryThumbnailAsset(pasteboardHistoryID: .init(rawValue: "1"), kind: .image, data: imageData)
        let detailWithThumb = detail(id: "1", title: "img", types: [.png], thumbnail: thumb)

        let shown = renderer(presentation(showsImage: true)).makeHistoryItems([detailWithThumb])
        #expect(shown[0].image != nil)

        let hidden = renderer(presentation(showsImage: false)).makeHistoryItems([detailWithThumb])
        #expect(hidden[0].image == nil)
    }

    @Test
    func colorPreviewShownOnlyWhenEnabled() {
        let imageData = NSImage.create(with: .red, size: NSSize(width: 10, height: 10)).tiffRepresentation!
        let thumb = PasteboardHistoryThumbnailAsset(pasteboardHistoryID: .init(rawValue: "1"), kind: .colorCode, data: imageData)
        let detailWithThumb = detail(id: "1", title: "#ff0000", thumbnail: thumb)

        #expect(renderer(presentation(showsColorPreview: true)).makeHistoryItems([detailWithThumb])[0].image != nil)
        // Enabling image previews must not surface a color-code thumbnail.
        #expect(renderer(presentation(showsImage: true, showsColorPreview: false)).makeHistoryItems([detailWithThumb])[0].image == nil)
    }

    @Test
    func folderItemsUseProvidedFolderIcon() {
        let icon = NSImage(size: NSSize(width: 10, height: 10))
        let items = renderer(presentation(numberOfItemsPlaceInline: 0, numberOfItemsPlaceInsideFolder: 2), folderIcon: icon)
            .makeHistoryItems(details(count: 2))
        #expect(items[0].image === icon)
    }

    // MARK: - No matches
    @Test
    func noMatchesItemIsDisabledAndInert() {
        let item = renderer(presentation()).makeNoMatchesItem(title: "No Matching History")
        #expect(item.title == "No Matching History")
        #expect(!item.isEnabled)
        #expect(item.action == nil)
        #expect(item.target == nil)
        #expect(item.representedObject == nil)
        #expect(item.toolTip == nil)
        #expect(item.submenu == nil)
        #expect(item.keyEquivalent.isEmpty)
    }
}
