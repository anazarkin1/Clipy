//
//  MenuManager.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/03/08.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa
import Combine
import Dependencies
import RxCocoa
import RxSwift

final class MenuManager: NSObject {

    // MARK: - Properties
    // Menus
    private var clipMenu: NSMenu?
    private var historyMenu: NSMenu?
    private var snippetMenu: NSMenu?
    // StatusMenu
    private lazy var statusBarItem: NSStatusItem = {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "\(Constants.Application.name)\(Bundle.main.appVersion ?? "")"
        item.menu = clipMenu
        return item
    }()
    // Search sessions (one per history-bearing menu)
    private let mainMenuSession = HistoryMenuSessionController()
    private let historyMenuSession = HistoryMenuSessionController()
    // Icon Cache
    private let folderIcon = NSImage(resource: .iconFolder)
    private let snippetIcon = NSImage(resource: .iconText)
    // Other
    private let disposeBag = DisposeBag()
    private let notificationCenter = NotificationCenter.default
    private let kMaxKeyEquivalents = 10

    @Dependency(\.pasteboardHistoryRepository)
    private var pasteboardHistoryRepository
    @Dependency(\.snippetRepository)
    private var snippetRepository
    @Dependency(\.mainQueue)
    private var mainQueue
    private var cancellables: Set<AnyCancellable> = []
    private var snippetFolderDetails = [SnippetFolderDetail]()

    // MARK: - Enum Values
    enum StatusType: Int {
        case none, black, white
    }

    // MARK: - Initialize
    override init() {
        super.init()
        folderIcon.isTemplate = true
        folderIcon.size = NSSize(width: 15, height: 13)
        snippetIcon.isTemplate = true
        snippetIcon.size = NSSize(width: 12, height: 13)
    }

    func setup() {
        bind()
    }

}

// MARK: - Popup Menu
extension MenuManager {
    func popUpMenu(_ type: MenuType) {
        let menu: NSMenu?
        switch type {
        case .main:
            menu = clipMenu
        case .history:
            menu = historyMenu
        case .snippet:
            menu = snippetMenu
        }
        // History-bearing menus manage their own focus via the search session
        // controller; the private first-item highlight must not race with it.
        if type == .snippet {
            menu?.highlightingFirstItemIfPossible()
        }
        menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func popUpSnippetFolder(_ folderDetail: SnippetFolderDetail) {
        let folderMenu = NSMenu(title: folderDetail.folder.title)
        // Folder title
        let labelItem = NSMenuItem(title: folderDetail.folder.title, action: nil)
        labelItem.isEnabled = false
        folderMenu.addItem(labelItem)
        // Snippets
        var index = firstIndexOfMenuItems()
        folderDetail.snippets
            .filter { $0.isEnabled }
            .forEach { snippet in
                let subMenuItem = makeSnippetMenuItem(snippet, listNumber: index)
                folderMenu.addItem(subMenuItem)
                index += 1
            }
        folderMenu.highlightingFirstItemIfPossible()
        folderMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Binding
private extension MenuManager {
    func bind() {
        pasteboardHistoryRepository.observeHistoryChanges()
            .receive(on: mainQueue)
            .sink { [weak self] _ in self?.createClipMenu() }
            .store(in: &cancellables)
        snippetRepository.observeFolderDetails()
            .receive(on: mainQueue)
            .sink { [weak self] folderDetails in
                self?.snippetFolderDetails = folderDetails
                self?.createClipMenu()
            }
            .store(in: &cancellables)
        // Menu icon
        AppEnvironment.current.defaults.rx.observe(Int.self, Constants.UserDefaults.showStatusItem, retainSelf: false)
            .compactMap { $0 }
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] key in
                self?.changeStatusItem(StatusType(rawValue: key) ?? .black)
            })
            .disposed(by: disposeBag)
        // Sort clips
        AppEnvironment.current.defaults.rx.observe(Bool.self, Constants.UserDefaults.reorderClipsAfterPasting, options: [.new], retainSelf: false)
            .compactMap { $0 }
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] _ in
                guard let wSelf = self else { return }
                wSelf.createClipMenu()
            })
            .disposed(by: disposeBag)
        // Edit snippets
        notificationCenter.rx.notification(Notification.Name(rawValue: Constants.Notification.closeSnippetEditor))
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] _ in
                self?.createClipMenu()
            })
            .disposed(by: disposeBag)
        // Observe change preference settings
        let defaults = AppEnvironment.current.defaults
        var menuChangedObservables = [Observable<Void>]()
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.addClearHistoryMenuItem, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Int.self, Constants.UserDefaults.maxHistorySize, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.showIconInTheMenu, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Int.self, Constants.UserDefaults.numberOfItemsPlaceInline, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Int.self, Constants.UserDefaults.numberOfItemsPlaceInsideFolder, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Int.self, Constants.UserDefaults.maxMenuItemTitleLength, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.menuItemsTitleStartWithZero, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.menuItemsAreMarkedWithNumbers, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.showToolTipOnMenuItem, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.showImageInTheMenu, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.addNumericKeyEquivalents, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Int.self, Constants.UserDefaults.maxLengthOfToolTip, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        menuChangedObservables.append(defaults.rx.observe(Bool.self, Constants.UserDefaults.showColorPreviewInTheMenu, options: [.new], retainSelf: false)
                                        .compactMap { $0 }.distinctUntilChanged().map { _ in })
        Observable.merge(menuChangedObservables)
            .throttle(.seconds(1), scheduler: MainScheduler.instance)
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] in
                self?.createClipMenu()
            })
            .disposed(by: disposeBag)
    }
}

// MARK: - Menus
private extension MenuManager {
     func createClipMenu() {
        clipMenu = NSMenu(title: Constants.Application.name)
        historyMenu = NSMenu(title: Constants.Menu.history)
        snippetMenu = NSMenu(title: Constants.Menu.snippet)

        // One snapshot feeds both history-bearing menus so they never fetch or
        // decrypt the same rows separately, and so a preference change cannot
        // split a render across two configurations.
        let snapshot = makeHistorySnapshot()
        installHistorySection(into: clipMenu!, session: mainMenuSession, snapshot: snapshot)
        installHistorySection(into: historyMenu!, session: historyMenuSession, snapshot: snapshot)

        addSnippetItems(clipMenu!, separateMenu: true, details: snippetFolderDetails)
        addSnippetItems(snippetMenu!, separateMenu: false, details: snippetFolderDetails)

        clipMenu?.addItem(NSMenuItem.separator())

        if AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.addClearHistoryMenuItem) {
            clipMenu?.addItem(NSMenuItem(title: String(localized: "Clear History"), action: #selector(AppDelegate.clearAllHistory)))
        }

        clipMenu?.addItem(NSMenuItem(title: String(localized: "Edit Snippets"), action: #selector(AppDelegate.showSnippetEditorWindow)))
        clipMenu?.addItem(NSMenuItem(title: String(localized: "Preferences"), action: #selector(AppDelegate.showPreferenceWindow)))
        clipMenu?.addItem(NSMenuItem.separator())
        clipMenu?.addItem(NSMenuItem(title: String(localized: "Quit Clipy"), action: #selector(AppDelegate.terminate)))

        statusBarItem.menu = clipMenu
    }

    func installHistorySection(into menu: NSMenu, session: HistoryMenuSessionController, snapshot: HistoryMenuSnapshot) {
        session.install(
            into: menu,
            snapshot: snapshot,
            action: #selector(AppDelegate.selectClipMenuItem(_:)),
            target: nil,
            folderIcon: folderIcon
        )
    }

    func menuItemTitle(_ title: String, listNumber: NSInteger, isMarkWithNumber: Bool) -> String {
        return (isMarkWithNumber) ? "\(listNumber). \(title)" : title
    }

    func makeSubmenuItem(_ title: String) -> NSMenuItem {
        let subMenu = NSMenu(title: "")
        let subMenuItem = NSMenuItem(title: title, action: nil)
        subMenuItem.submenu = subMenu
        subMenuItem.image = (AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.showIconInTheMenu)) ? folderIcon : nil
        return subMenuItem
    }
}

// MARK: - Clips
private extension MenuManager {
    /// Builds one immutable snapshot of history details plus presentation
    /// preferences, fetching/decoding history exactly once.
    func makeHistorySnapshot() -> HistoryMenuSnapshot {
        let presentation = makeHistoryPresentation()
        let details = fetchHistoryDetails(presentation: presentation)
        return HistoryMenuSnapshot(details: details, presentation: presentation)
    }

    /// Captures the current menu presentation preferences into an immutable value.
    func makeHistoryPresentation() -> HistoryMenuPresentation {
        let defaults = AppEnvironment.current.defaults
        return HistoryMenuPresentation(
            firstListNumber: firstIndexOfMenuItems(),
            isMarkedWithNumbers: defaults.bool(forKey: Constants.UserDefaults.menuItemsAreMarkedWithNumbers),
            addsNumericKeyEquivalents: defaults.bool(forKey: Constants.UserDefaults.addNumericKeyEquivalents),
            maxKeyEquivalents: kMaxKeyEquivalents,
            numberOfItemsPlaceInline: defaults.integer(forKey: Constants.UserDefaults.numberOfItemsPlaceInline),
            numberOfItemsPlaceInsideFolder: defaults.integer(forKey: Constants.UserDefaults.numberOfItemsPlaceInsideFolder),
            showsImage: defaults.bool(forKey: Constants.UserDefaults.showImageInTheMenu),
            showsColorPreview: defaults.bool(forKey: Constants.UserDefaults.showColorPreviewInTheMenu),
            showsFolderIcon: defaults.bool(forKey: Constants.UserDefaults.showIconInTheMenu),
            thumbnailWidth: defaults.integer(forKey: Constants.UserDefaults.thumbnailWidth),
            thumbnailHeight: defaults.integer(forKey: Constants.UserDefaults.thumbnailHeight),
            showsToolTip: defaults.bool(forKey: Constants.UserDefaults.showToolTipOnMenuItem),
            maxLengthOfToolTip: defaults.integer(forKey: Constants.UserDefaults.maxLengthOfToolTip)
        )
    }

    func fetchHistoryDetails(presentation: HistoryMenuPresentation) -> [PasteboardHistoryDetail] {
        let defaults = AppEnvironment.current.defaults
        let reorderClipsAfterPasting = defaults.bool(forKey: Constants.UserDefaults.reorderClipsAfterPasting)
        let maxHistory = defaults.integer(forKey: Constants.UserDefaults.maxHistorySize)
        return pasteboardHistoryRepository.fetchHistoryDetails(
            sortsByCreatedAt: !reorderClipsAfterPasting,
            includesThumbnailAsset: presentation.showsImage || presentation.showsColorPreview,
            limit: maxHistory
        )
    }
}

// MARK: - Snippets
private extension MenuManager {
    func addSnippetItems(_ menu: NSMenu, separateMenu: Bool, details: [SnippetFolderDetail]) {
        guard !details.isEmpty else { return }

        if separateMenu {
            menu.addItem(NSMenuItem.separator())
        }

        // Snippet title
        let labelItem = NSMenuItem(title: String(localized: "Snippet"), action: nil)
        labelItem.isEnabled = false
        menu.addItem(labelItem)

        var subMenuIndex = menu.numberOfItems - 1
        let firstIndex = firstIndexOfMenuItems()
        details
            .filter { $0.folder.isEnabled }
            .forEach { detail in
                let folderTitle = detail.folder.title
                let subMenuItem = makeSubmenuItem(folderTitle)
                menu.addItem(subMenuItem)
                subMenuIndex += 1

                var i = firstIndex
                detail.snippets
                    .filter { $0.isEnabled }
                    .forEach { snippet in
                        let subMenuItem = makeSnippetMenuItem(snippet, listNumber: i)
                        if let subMenu = menu.item(at: subMenuIndex)?.submenu {
                            subMenu.addItem(subMenuItem)
                            i += 1
                        }
                    }
            }
    }

    func makeSnippetMenuItem(_ snippet: Snippet, listNumber: Int) -> NSMenuItem {
        let isMarkWithNumber = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.menuItemsAreMarkedWithNumbers)
        let isShowIcon = AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.showIconInTheMenu)

        let titleWithMark = menuItemTitle(snippet.title.trimmedMenuTitle, listNumber: listNumber, isMarkWithNumber: isMarkWithNumber)

        let menuItem = NSMenuItem(title: titleWithMark, action: #selector(AppDelegate.selectSnippetMenuItem(_:)), keyEquivalent: "")
        menuItem.representedObject = snippet.id
        menuItem.toolTip = snippet.toolTip
        menuItem.image = (isShowIcon) ? snippetIcon : nil

        return menuItem
    }
}

// MARK: - Status Item
private extension MenuManager {
    func changeStatusItem(_ type: StatusType) {
        switch type {
        case .black:
            let image = NSImage(resource: .statusbarMenuBlack)
            image.isTemplate = true
            statusBarItem.button?.image = image
            statusBarItem.isVisible = true
        case .white:
            let image = NSImage(resource: .statusbarMenuWhite)
            image.isTemplate = true
            statusBarItem.button?.image = image
            statusBarItem.isVisible = true
        case .none:
            statusBarItem.isVisible = false
        }
    }
}

// MARK: - Settings
private extension MenuManager {
    func firstIndexOfMenuItems() -> NSInteger {
        return AppEnvironment.current.defaults.bool(forKey: Constants.UserDefaults.menuItemsTitleStartWithZero) ? 0 : 1
    }
}
