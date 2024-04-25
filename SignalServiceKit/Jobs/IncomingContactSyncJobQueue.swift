//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public extension Notification.Name {
    static let incomingContactSyncDidComplete = Notification.Name("IncomingContactSyncDidComplete")
}

public class IncomingContactSyncJobQueue: NSObject {
    public enum Constants {
        public static let insertedThreads = "insertedThreads"
    }

    private let jobQueueRunner: JobQueueRunner<
        JobRecordFinderImpl<IncomingContactSyncJobRecord>,
        IncomingContactSyncJobRunnerFactory
    >

    public init(db: DB, reachabilityManager: SSKReachabilityManager) {
        self.jobQueueRunner = JobQueueRunner(
            canExecuteJobsConcurrently: false,
            db: db,
            jobFinder: JobRecordFinderImpl(db: db),
            jobRunnerFactory: IncomingContactSyncJobRunnerFactory()
        )
        super.init()
        self.jobQueueRunner.listenForReachabilityChanges(reachabilityManager: reachabilityManager)
    }

    public func start(appContext: AppContext) {
        jobQueueRunner.start(shouldRestartExistingJobs: appContext.isMainApp)
    }

    public func add(
        downloadMetadata: AttachmentDownloads.DownloadMetadata,
        isComplete: Bool,
        tx: SDSAnyWriteTransaction
    ) {
        let jobRecord = IncomingContactSyncJobRecord(
            cdnNumber: downloadMetadata.cdnNumber,
            cdnKey: downloadMetadata.cdnKey,
            encryptionKey: downloadMetadata.encryptionKey,
            digest: downloadMetadata.digest,
            plaintextLength: downloadMetadata.plaintextLength,
            isCompleteContactSync: isComplete
        )
        jobRecord.anyInsert(transaction: tx)
        tx.addSyncCompletion { self.jobQueueRunner.addPersistedJob(jobRecord) }
    }
}

private class IncomingContactSyncJobRunnerFactory: JobRunnerFactory {
    func buildRunner() -> IncomingContactSyncJobRunner { return IncomingContactSyncJobRunner() }
}

private class IncomingContactSyncJobRunner: JobRunner, Dependencies {
    private enum Constants {
        static let maxRetries: UInt = 4
    }

    func runJobAttempt(_ jobRecord: IncomingContactSyncJobRecord) async -> JobAttemptResult {
        return await JobAttemptResult.executeBlockWithDefaultErrorHandler(
            jobRecord: jobRecord,
            retryLimit: Constants.maxRetries,
            db: DependenciesBridge.shared.db,
            block: { try await _runJob(jobRecord) }
        )
    }

    func didFinishJob(_ jobRecordId: JobRecord.RowId, result: JobResult) async {}

    private func _runJob(_ jobRecord: IncomingContactSyncJobRecord) async throws {
        let fileUrl: URL
        let legacyAttachmentId: String?
        switch jobRecord.downloadInfo {
        case .invalid:
            owsFailDebug("Invalid contact sync job!")
            await databaseStorage.awaitableWrite { tx in
                jobRecord.anyRemove(transaction: tx)
            }
            return
        case .legacy(let attachmentId):
            guard let attachment = (databaseStorage.read { transaction in
                return TSAttachment.anyFetch(uniqueId: attachmentId, transaction: transaction)
            }) else {
                throw OWSAssertionError("missing attachment")
            }

            let attachmentStream: TSAttachmentStream
            switch attachment {
            case let attachmentPointer as TSAttachmentPointer:
                attachmentStream = try await TSAttachmentDownloadManager()
                    .enqueueContactSyncDownload(attachmentPointer: attachmentPointer)
            case let attachmentStreamValue as TSAttachmentStream:
                attachmentStream = attachmentStreamValue
            default:
                throw OWSAssertionError("unexpected attachment type: \(attachment)")
            }
            guard let url = attachmentStream.originalMediaURL else {
                throw OWSAssertionError("fileUrl was unexpectedly nil")
            }
            fileUrl = url
            legacyAttachmentId = attachmentStream.uniqueId
        case .transient(let downloadMetadata):
            fileUrl = try await DependenciesBridge.shared.attachmentDownloadManager.downloadTransientAttachment(
                metadata: downloadMetadata
            ).awaitable()
            legacyAttachmentId = nil
        }

        let insertedThreads = try await firstly(on: DispatchQueue.global()) {
            try self.processContactSync(decryptedFileUrl: fileUrl, isComplete: jobRecord.isCompleteContactSync)
        }.awaitable()
        await databaseStorage.awaitableWrite { tx in
            if let legacyAttachmentId {
                TSAttachmentStream.anyFetch(uniqueId: legacyAttachmentId, transaction: tx)?.anyRemove(transaction: tx)
            }
            jobRecord.anyRemove(transaction: tx)
        }
        NotificationCenter.default.post(name: .incomingContactSyncDidComplete, object: self, userInfo: [
            IncomingContactSyncJobQueue.Constants.insertedThreads: insertedThreads
        ])
    }

    // MARK: - Private

    private func processContactSync(
        decryptedFileUrl fileUrl: URL,
        isComplete: Bool
    ) throws -> [(threadUniqueId: String, sortOrder: UInt32)] {

        var insertedThreads = [(threadUniqueId: String, sortOrder: UInt32)]()
        try Data(contentsOf: fileUrl, options: .mappedIfSafe).withUnsafeBytes { bufferPtr in
            if let baseAddress = bufferPtr.baseAddress, bufferPtr.count > 0 {
                let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                let inputStream = ChunkedInputStream(forReadingFrom: pointer, count: bufferPtr.count)
                let contactStream = ContactsInputStream(inputStream: inputStream)

                // We use batching to avoid long-running write transactions
                // and to place an upper bound on memory usage.
                var allPhoneNumbers = [E164]()
                while try processBatch(
                    contactStream: contactStream,
                    insertedThreads: &insertedThreads,
                    processedPhoneNumbers: &allPhoneNumbers
                ) {}

                if isComplete {
                    try pruneContacts(exceptThoseReceivedFromCompleteSync: allPhoneNumbers)
                }

                databaseStorage.write { transaction in
                    // Always fire just one identity change notification, rather than potentially
                    // once per contact. It's possible that *no* identities actually changed,
                    // but we have no convenient way to track that.
                    let identityManager = DependenciesBridge.shared.identityManager
                    identityManager.fireIdentityStateChangeNotification(after: transaction.asV2Write)
                }
            }
        }
        return insertedThreads
    }

    // Returns false when there are no more contacts to process.
    private func processBatch(
        contactStream: ContactsInputStream,
        insertedThreads: inout [(threadUniqueId: String, sortOrder: UInt32)],
        processedPhoneNumbers: inout [E164]
    ) throws -> Bool {
        try autoreleasepool {
            // We use batching to avoid long-running write transactions.
            guard let contactBatch = try Self.buildBatch(contactStream: contactStream) else {
                return false
            }
            guard !contactBatch.isEmpty else {
                owsFailDebug("Empty batch.")
                return false
            }
            try databaseStorage.write { tx in
                for contact in contactBatch {
                    if let phoneNumber = try processContactDetails(contact, insertedThreads: &insertedThreads, tx: tx) {
                        processedPhoneNumbers.append(phoneNumber)
                    }
                }
            }
            return true
        }
    }

    private static func buildBatch(contactStream: ContactsInputStream) throws -> [ContactDetails]? {
        let batchSize = 8
        var contacts = [ContactDetails]()
        while contacts.count < batchSize, let contact = try contactStream.decodeContact() {
            contacts.append(contact)
        }
        guard !contacts.isEmpty else {
            return nil
        }
        return contacts
    }

    private func processContactDetails(
        _ contactDetails: ContactDetails,
        insertedThreads: inout [(threadUniqueId: String, sortOrder: UInt32)],
        tx: SDSAnyWriteTransaction
    ) throws -> E164? {
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager
        guard let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx.asV2Read) else {
            throw OWSGenericError("Not registered.")
        }

        let recipientFetcher = DependenciesBridge.shared.recipientFetcher
        let recipientManager = DependenciesBridge.shared.recipientManager
        let recipientMerger = DependenciesBridge.shared.recipientMerger

        let recipient: SignalRecipient
        if let aci = contactDetails.aci {
            recipient = recipientMerger.applyMergeFromContactSync(
                localIdentifiers: localIdentifiers,
                aci: aci,
                phoneNumber: contactDetails.phoneNumber,
                tx: tx.asV2Write
            )
            // Mark as registered only if we have a UUID (we always do in this branch).
            // If we don't have a UUID, contacts can't be registered.
            recipientManager.markAsRegisteredAndSave(recipient, shouldUpdateStorageService: false, tx: tx.asV2Write)
        } else if let phoneNumber = contactDetails.phoneNumber {
            recipient = recipientFetcher.fetchOrCreate(phoneNumber: phoneNumber, tx: tx.asV2Write)
        } else {
            throw OWSAssertionError("No identifier in ContactDetails.")
        }

        let address = recipient.address

        let contactThread: TSContactThread
        let isNewThread: Bool
        if let existingThread = TSContactThread.getWithContactAddress(address, transaction: tx) {
            contactThread = existingThread
            isNewThread = false
        } else {
            let newThread = TSContactThread(contactAddress: address)
            newThread.shouldThreadBeVisible = true

            contactThread = newThread
            isNewThread = true
        }

        if isNewThread {
            contactThread.anyInsert(transaction: tx)
            let inboxSortOrder = contactDetails.inboxSortOrder ?? UInt32.max
            insertedThreads.append((threadUniqueId: contactThread.uniqueId, sortOrder: inboxSortOrder))
        }

        let disappearingMessageToken = DisappearingMessageToken.token(forProtoExpireTimer: contactDetails.expireTimer)
        GroupManager.remoteUpdateDisappearingMessages(
            withContactThread: contactThread,
            disappearingMessageToken: disappearingMessageToken,
            changeAuthor: nil,
            localIdentifiers: LocalIdentifiersObjC(localIdentifiers),
            transaction: tx
        )

        return contactDetails.phoneNumber
    }

    /// Clear ``SignalAccount``s that weren't part of a complete sync.
    ///
    /// Although "system contact" details (represented by a ``SignalAccount``)
    /// are synced via StorageService rather than contact sync messages, any
    /// contacts not included in a complete contact sync are not present on the
    /// primary device and should there be removed from this linked device.
    ///
    /// In theory, StorageService updates should handle removing these contacts.
    /// However, there's no periodic sync check our state against
    /// StorageService, so this job continues to fulfill that role. In the
    /// future, if you're removing this method, you should first ensure that
    /// periodic full syncs of contact details happen with StorageService.
    private func pruneContacts(exceptThoseReceivedFromCompleteSync phoneNumbers: [E164]) throws {
        try self.databaseStorage.write { transaction in
            // Every contact sync includes your own address. However, we shouldn't
            // create a SignalAccount for your own address. (If you're a primary, this
            // is handled by FetchedSystemContacts.phoneNumbers(…).)
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            guard let localIdentifiers = tsAccountManager.localIdentifiers(tx: transaction.asV2Read) else {
                throw OWSGenericError("Not registered.")
            }
            let setOfPhoneNumbers = Set(phoneNumbers.lazy.filter { !localIdentifiers.contains(phoneNumber: $0) })

            // Rather than collecting SignalAccount objects, collect their unique IDs.
            // This operation can run in the memory-constrainted NSE, so trade off a
            // bit of speed to save memory.
            var uniqueIdsToRemove = [String]()
            SignalAccount.anyEnumerate(transaction: transaction, batchingPreference: .batched(8)) { signalAccount, _ in
                if let phoneNumber = E164(signalAccount.recipientPhoneNumber), setOfPhoneNumbers.contains(phoneNumber) {
                    // This contact was received in this batch, so don't remove it.
                    return
                }
                uniqueIdsToRemove.append(signalAccount.uniqueId)
            }
            Logger.info("Removing \(uniqueIdsToRemove.count) contacts during contact sync")
            for uniqueId in uniqueIdsToRemove {
                autoreleasepool {
                    guard let signalAccount = SignalAccount.anyFetch(uniqueId: uniqueId, transaction: transaction) else {
                        return
                    }
                    signalAccount.anyRemove(transaction: transaction)
                }
            }
            if !uniqueIdsToRemove.isEmpty {
                contactsManagerImpl.didUpdateSignalAccounts(transaction: transaction)
            }
        }
    }
}
