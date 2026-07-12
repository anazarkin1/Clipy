//
//  PasteboardHistoryRepository.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Shunsuke Furubayashi on 2026/05/28.
//
//  Copyright © 2015-2026 Clipy Project.
//

import AppKit
import Combine
import Dependencies
import SQLiteData

protocol PasteboardHistoryRepositoryProtocol {
    var usesEncryptedHistoryStorage: Bool { get }

    func observeHistories() -> AnyPublisher<[PasteboardHistory], Never>
    func observeHistoryChanges() -> AnyPublisher<Void, Never>
    func hasHistories() -> Bool
    func fetchHistoryDetails(
        sortsByCreatedAt: Bool,
        includesThumbnailAsset: Bool,
        limit: Int,
    ) -> [PasteboardHistoryDetail]
    func fetchHistory(id: PasteboardHistory.ID) -> PasteboardHistory?
    func fetchContent(id: PasteboardHistory.ID) -> PasteboardContent?

    func save(id: PasteboardHistory.ID, content: PasteboardContent, updateAt: Int)
    func updateOCRText(id: PasteboardHistory.ID, ocrText: String)
    func deleteHistory(id: PasteboardHistory.ID)
    func deleteAll()
    func deleteOverflowingHistories(maxHistorySize: Int)
}

final class PasteboardHistoryRepository: PasteboardHistoryRepositoryProtocol {
    @Dependency(\.defaultDatabase)
    private var database

    @FetchAll(PasteboardHistory.all.order { $0.updateAt.desc() })
    private var histories

    @FetchAll(PasteboardHistory.select { $0.id }.order { $0.updateAt.desc() })
    private var historyIDs

    var usesEncryptedHistoryStorage: Bool {
        currentMetadataMode() == .encrypted
    }

    /// Content-free revision signal fired after a successful write whose effect
    /// the id-observation cannot see — notably an OCR-only update, which changes
    /// no id and no `updateAt` and therefore leaves the observed id list equal.
    /// Only `Void` crosses this subject; no title, OCR, asset, or ciphertext is
    /// ever published.
    private let revisionSubject = PassthroughSubject<Void, Never>()

    func observeHistories() -> AnyPublisher<[PasteboardHistory], Never> {
        _historyIDs.publisher
            .map { [weak self] _ in
                guard let self else { return [] }
                return self
                    .fetchHistoryDetails(sortsByCreatedAt: false, includesThumbnailAsset: false, limit: Int.max)
                    .map(\.history)
            }
            .eraseToAnyPublisher()
    }

    func observeHistoryChanges() -> AnyPublisher<Void, Never> {
        // Insert/delete/reorder move the observed id list and emit here; an
        // OCR-only update leaves that list equal, so it is delivered via the
        // content-free revision subject instead.
        _historyIDs.publisher
            .map { _ in () }
            .merge(with: revisionSubject)
            .eraseToAnyPublisher()
    }

    func hasHistories() -> Bool {
        return withErrorReporting {
            try database.read { database in
                try PasteboardHistory
                    .select { $0.id }
                    .limit(1)
                    .fetchOne(database) != nil
            }
        } ?? false
    }

    func fetchHistoryDetails(
        sortsByCreatedAt: Bool,
        includesThumbnailAsset: Bool,
        limit: Int
    ) -> [PasteboardHistoryDetail] {
        guard allowsHistoryServices() else { return [] }
        return withErrorReporting {
            try database.read { database in
                let histories = PasteboardHistory
                    .all
                    .order { columns in
                        if sortsByCreatedAt {
                            columns.createdAt.desc()
                        } else {
                            columns.updateAt.desc()
                        }
                    }
                    .limit(limit)

                let cryptoService = try CryptoService(database: database)

                guard includesThumbnailAsset else {
                    let storedHistories = try histories.fetchAll(database)
                    return storedHistories.compactMap {
                        decryptedHistoryDetail(
                            history: $0,
                            thumbnailAsset: nil,
                            cryptoService: cryptoService
                        )
                    }
                }

                let storedDetails = try histories
                    .leftJoin(PasteboardHistoryThumbnailAsset.all) { $0.id.eq($1.pasteboardHistoryID) }
                    .select { PasteboardHistoryDetail.Columns(history: $0, thumbnailAsset: $1) }
                    .fetchAll(database)
                return storedDetails.compactMap {
                    decryptedHistoryDetail(
                        history: $0.history,
                        thumbnailAsset: $0.thumbnailAsset,
                        cryptoService: cryptoService
                    )
                }
            }
        } ?? []
    }

    func fetchHistory(id: PasteboardHistory.ID) -> PasteboardHistory? {
        guard allowsHistoryServices() else { return nil }
        return withErrorReporting {
            try database.read { database in
                guard let history = try PasteboardHistory.find(id).fetchOne(database) else { return nil }
                do {
                    return try decryptedHistory(history, cryptoService: try CryptoService(database: database))
                } catch {
                    return nil
                }
            }
        }
    }

    func fetchContent(id: PasteboardHistory.ID) -> PasteboardContent? {
        guard allowsHistoryServices() else { return nil }
        return withErrorReporting {
            try database.read { database in
                let assets = try PasteboardHistoryAsset
                    .where { $0.pasteboardHistoryID.eq(id) }
                    .order(by: \.index)
                    .fetchAll(database)
                let cryptoService = try CryptoService(database: database)
                do {
                    return PasteboardContent(
                        assets: try assets.map {
                            PasteboardContent.Asset(
                                type: $0.pasteboardType,
                                data: try cryptoService?.openAsset($0) ?? $0.data
                            )
                        }
                    )
                } catch {
                    return nil
                }
            }
        }
    }

    func save(id: PasteboardHistory.ID, content: PasteboardContent, updateAt: Int) {
        guard allowsHistoryServices() else { return }
        withErrorReporting {
            try database.write { database in
                if let cryptoService = try CryptoService(database: database) {
                    try saveEncrypted(content: content, updateAt: updateAt, cryptoService: cryptoService, database: database)
                    return
                }

                let existingHistory = try PasteboardHistory
                    .find(id)
                    .fetchOne(database)
                let history = PasteboardHistory(
                    id: id,
                    title: String(content.stringValue.prefix(10000)),
                    ocrText: existingHistory?.ocrText,
                    pasteboardTypes: content.types,
                    createdAt: existingHistory?.createdAt ?? updateAt,
                    updateAt: updateAt,
                    deviceID: CPYUtilities.deviceID
                )
                try PasteboardHistory
                    .upsert { history }
                    .execute(database)
                // When a history already exists, its ID is derived from the content hash,
                // so the assets are guaranteed to be identical and do not need to be inserted again.
                if existingHistory == nil {
                    let assets = content.assets.enumerated().map { index, asset in
                        PasteboardHistoryAsset.Draft(
                            pasteboardHistoryID: id,
                            index: index,
                            pasteboardType: asset.type,
                            data: asset.data
                        )
                    }
                    try PasteboardHistoryAsset.insert { assets }.execute(database)
                    if let thumbnailAsset = thumbnailAsset(from: content, id: id) {
                        try PasteboardHistoryThumbnailAsset.insert { thumbnailAsset }.execute(database)
                    }
                }
            }
        }
    }

    func updateOCRText(id: PasteboardHistory.ID, ocrText: String) {
        guard allowsHistoryServices() else { return }
        let committed = withErrorReporting { () -> Bool in
            try database.write { database in
                let cryptoService = try CryptoService(database: database)
                let ocrTextData = try cryptoService?.sealHistoryOCR(Data(ocrText.utf8), historyID: id) ?? Data(ocrText.utf8)
                try PasteboardHistory
                    .find(id)
                    .update { $0.ocrTextData = #bind(ocrTextData) }
                    .execute(database)
            }
            return true
        }
        if committed == true {
            // An OCR-only update does not move the observed id list, so publish a
            // content-free revision so open menus re-render with the new OCR text.
            revisionSubject.send(())
        }
    }

    func deleteHistory(id: PasteboardHistory.ID) {
        withErrorReporting {
            try database.write { database in
                try PasteboardHistory
                    .delete()
                    .where { $0.id.eq(id) }
                    .execute(database)
            }
        }
    }

    func deleteAll() {
        withErrorReporting {
            try database.write { database in
                try PasteboardHistory.delete().execute(database)
            }
        }
    }

    func deleteOverflowingHistories(maxHistorySize: Int) {
        guard maxHistorySize > 0 else {
            deleteAll()
            return
        }
        withErrorReporting {
            try database.write { database in
                let deletingIDs = try PasteboardHistory
                    .order { $0.updateAt.desc() }
                    .limit(-1, offset: maxHistorySize)
                    .select { $0.id }
                    .fetchAll(database)
                guard !deletingIDs.isEmpty else { return }
                try PasteboardHistory
                    .delete()
                    .where { $0.id.in(deletingIDs) }
                    .execute(database)
            }
        }
    }
}

private extension PasteboardHistoryRepository {
    func allowsHistoryServices() -> Bool {
        let metadataMode = currentMetadataMode()
        switch HistorySecurityBootstrap.startupState {
        case .plaintext:
            return metadataMode == .plaintext
        case .unlocked:
            // Encrypted mode is available for the matching encrypted database.
            // Plaintext mode remains available if a stale process-wide unlocked
            // state is observed while this repository is bound to a plaintext
            // test/preview database.
            return metadataMode == .encrypted || metadataMode == .plaintext
        case .blockedByOrphanKeys, .locked, .keyMissing, .keyUnavailable, .corrupt:
            // These blocked states should only suppress encrypted/protected
            // databases. A plaintext database in another dependency context
            // should not be bricked by stale process-wide state.
            return metadataMode == .plaintext
        case let .transitioning(transitionMode):
            return metadataMode != transitionMode && metadataMode == .plaintext
        }
    }

    func currentMetadataMode() -> HistorySecurityMode? {
        let mode: HistorySecurityMode?? = withErrorReporting {
            try database.read { database in
                try #sql(
                    """
                    SELECT "mode"
                    FROM "historySecurityMetadata"
                    WHERE "id" = 1
                    """,
                    as: String.self
                )
                .fetchOne(database)
                .flatMap(HistorySecurityMode.init(rawValue:))
            }
        }
        return mode.flatMap { $0 }
    }

    func saveEncrypted(
        content: PasteboardContent,
        updateAt: Int,
        cryptoService: CryptoService,
        database: Database
    ) throws {
        let id = cryptoService.historyID(for: content)
        let existingHistory = try PasteboardHistory
            .find(id)
            .fetchOne(database)
        let ocrTextData = existingHistory?.ocrTextData
        let titleData = try cryptoService.sealHistoryTitle(Data(String(content.stringValue.prefix(10000)).utf8), historyID: id)
        let history = PasteboardHistory(
            id: id,
            titleData: titleData,
            ocrTextData: ocrTextData,
            pasteboardTypes: content.types,
            createdAt: existingHistory?.createdAt ?? updateAt,
            updateAt: updateAt,
            deviceID: CPYUtilities.deviceID
        )
        try PasteboardHistory
            .upsert { history }
            .execute(database)

        guard existingHistory == nil else { return }

        let assets = try content.assets.enumerated().map { index, asset in
            let storedAsset = PasteboardHistoryAsset(
                id: .init(UUID()),
                pasteboardHistoryID: id,
                index: index,
                pasteboardType: asset.type,
                data: asset.data
            )
            return PasteboardHistoryAsset(
                id: storedAsset.id,
                pasteboardHistoryID: storedAsset.pasteboardHistoryID,
                index: storedAsset.index,
                pasteboardType: storedAsset.pasteboardType,
                data: try cryptoService.sealAsset(storedAsset.data, asset: storedAsset)
            )
        }
        try PasteboardHistoryAsset.insert { assets }.execute(database)

        if let thumbnailAsset = thumbnailAsset(from: content, id: id) {
            let encryptedThumbnailAsset = PasteboardHistoryThumbnailAsset(
                pasteboardHistoryID: thumbnailAsset.pasteboardHistoryID,
                kind: thumbnailAsset.kind,
                data: try cryptoService.sealThumbnail(thumbnailAsset)
            )
            try PasteboardHistoryThumbnailAsset.insert { encryptedThumbnailAsset }.execute(database)
        }
    }

    func decryptedHistoryDetail(
        history: PasteboardHistory,
        thumbnailAsset: PasteboardHistoryThumbnailAsset?,
        cryptoService: CryptoService?
    ) -> PasteboardHistoryDetail? {
        do {
            let history = try decryptedHistory(history, cryptoService: cryptoService)
            let thumbnailAsset = try decryptedThumbnailAsset(thumbnailAsset, cryptoService: cryptoService)
            return PasteboardHistoryDetail(history: history, thumbnailAsset: thumbnailAsset)
        } catch {
            return nil
        }
    }

    func decryptedHistory(
        _ history: PasteboardHistory,
        cryptoService: CryptoService?
    ) throws -> PasteboardHistory {
        guard let cryptoService else { return history }
        return PasteboardHistory(
            id: history.id,
            titleData: try cryptoService.openHistoryTitle(history.titleData, historyID: history.id),
            ocrTextData: try history.ocrTextData.map {
                try cryptoService.openHistoryOCR($0, historyID: history.id)
            },
            pasteboardTypes: history.pasteboardTypes,
            createdAt: history.createdAt,
            updateAt: history.updateAt,
            deviceID: history.deviceID
        )
    }

    func decryptedThumbnailAsset(
        _ thumbnailAsset: PasteboardHistoryThumbnailAsset?,
        cryptoService: CryptoService?
    ) throws -> PasteboardHistoryThumbnailAsset? {
        guard let thumbnailAsset, let cryptoService else { return thumbnailAsset }
        return PasteboardHistoryThumbnailAsset(
            pasteboardHistoryID: thumbnailAsset.pasteboardHistoryID,
            kind: thumbnailAsset.kind,
            data: try cryptoService.openThumbnail(thumbnailAsset)
        )
    }

    func thumbnailAsset(from content: PasteboardContent, id: PasteboardHistory.ID) -> PasteboardHistoryThumbnailAsset? {
        var asset: PasteboardHistoryThumbnailAsset?
        if let thumbnailImage = content.thumbnailImage, let thumbnailData = thumbnailImage.tiffRepresentation {
            asset = PasteboardHistoryThumbnailAsset(
                pasteboardHistoryID: id,
                kind: .image,
                data: thumbnailData
            )
        }
        if let colorCodeImage = content.colorCodeImage, let colorCodeData = colorCodeImage.tiffRepresentation {
            asset = PasteboardHistoryThumbnailAsset(
                pasteboardHistoryID: id,
                kind: .colorCode,
                data: colorCodeData
            )
        }
        return asset
    }
}

private enum PasteboardHistoryRepositoryKey: DependencyKey {
    static let liveValue: any PasteboardHistoryRepositoryProtocol = PasteboardHistoryRepository()
}

extension DependencyValues {
    var pasteboardHistoryRepository: PasteboardHistoryRepositoryProtocol {
        get { self[PasteboardHistoryRepositoryKey.self] }
        set { self[PasteboardHistoryRepositoryKey.self] = newValue }
    }
}
