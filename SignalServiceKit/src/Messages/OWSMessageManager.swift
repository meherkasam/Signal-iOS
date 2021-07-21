//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import SignalClient

@objc
public enum SealedSenderContentHint: Int {
    case `default` = 0
    case resendable
    case implicit

    init(_ signalClientHint: UnidentifiedSenderMessageContent.ContentHint) {
        switch signalClientHint {
        case .default: self = .default
        case .resendable: self = .resendable
        case .implicit: self = .implicit
        default:
            owsFailDebug("Unspecified case \(signalClientHint)")
            self = .default
        }
    }

    public var signalClientHint: UnidentifiedSenderMessageContent.ContentHint {
        switch self {
        case .default: return .default
        case .resendable: return .resendable
        case .implicit: return .implicit
        }
    }
}

extension OWSMessageManager {

    @objc
    func handleIncomingEnvelope(
        _ envelope: SSKProtoEnvelope,
        withSenderKeyDistributionMessage skdmData: Data,
        transaction writeTx: SDSAnyWriteTransaction) {

        guard envelope.sourceAddress?.isValid == true else {
            return owsFailDebug("Invalid source address")
        }

        do {
            let skdm = try SenderKeyDistributionMessage(bytes: skdmData.map { $0 })
            guard let sourceAddress = envelope.sourceUuid else {
                throw OWSAssertionError("SenderKeyDistributionMessages must be sent from senders with UUID")
            }
            let sourceDeviceId = envelope.sourceDevice
            let protocolAddress = try ProtocolAddress(name: sourceAddress, deviceId: sourceDeviceId)
            try processSenderKeyDistributionMessage(skdm, from: protocolAddress, store: senderKeyStore, context: writeTx)
        } catch {
            owsFailDebug("Failed to process incoming sender key \(error)")
        }
    }

    @objc
    func handleIncomingEnvelope(
        _ envelope: SSKProtoEnvelope,
        withDecryptionErrorMessage bytes: Data,
        transaction writeTx: SDSAnyWriteTransaction
    ) {
        guard let sourceAddress = envelope.sourceAddress, sourceAddress.isValid,
              let sourceUuid = envelope.sourceUuid else {
            return owsFailDebug("Invalid source address")
        }
        let sourceDeviceId = envelope.sourceDevice

        do {
            let errorMessage = try DecryptionErrorMessage(bytes: bytes)
            guard errorMessage.deviceId == tsAccountManager.storedDeviceId() else {
                // Not for this device. Let the other device handle this.
                Logger.info("")
                return
            }
            let protocolAddress = try ProtocolAddress(name: sourceUuid, deviceId: sourceDeviceId)

            // If a ratchet key is included, this was a 1:1 session message
            // Archive the session if the current key matches.
            if let ratchetKey = errorMessage.ratchetKey {
                let sessionRecord = try sessionStore.loadSession(for: protocolAddress, context: writeTx)
                if try sessionRecord?.currentRatchetKeyMatches(ratchetKey) == true {
                    sessionStore.archiveSession(for: sourceAddress,
                                                deviceId: Int32(sourceDeviceId),
                                                transaction: writeTx)
                }
            }

            Logger.warn("Attempt to retry message \(errorMessage)")
            let resendResponse = OWSOutgoingResendResponse(
                address: sourceAddress,
                deviceId: Int64(sourceDeviceId),
                failedTimestamp: Int64(errorMessage.timestamp),
                transaction: writeTx
            )
            messageSenderJobQueue.add(message: resendResponse.asPreparer, transaction: writeTx)

        } catch {
            owsFailDebug("Failed to process decryption error message \(error)")
        }
    }
}
