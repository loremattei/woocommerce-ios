import Foundation
import Networking
import Storage


// MARK: - ShipmentStore
//
public class ShipmentStore: Store {

    /// Shared private StorageType for use during then entire ShipmentStore sync process
    ///
    private lazy var sharedDerivedStorage: StorageType = {
        return storageManager.newDerivedStorage()
    }()

    /// Registers for supported Actions.
    ///
    override public func registerSupportedActions(in dispatcher: Dispatcher) {
        dispatcher.register(processor: self, for: ShipmentAction.self)
    }

    /// Receives and executes Actions.
    ///
    override public func onAction(_ action: Action) {
        guard let action = action as? ShipmentAction else {
            assertionFailure("ShipmentStore received an unsupported action")
            return
        }

        switch action {
        case .synchronizeShipmentTrackingData(let siteID, let orderID, let onCompletion):
            synchronizeShipmentTrackingData(siteID: siteID, orderID: orderID, onCompletion: onCompletion)
        case .synchronizeShipmentTrackingProviders(let siteID, let orderID, let onCompletion):
            syncronizeShipmentTrackingProviderGroupsData(siteID: siteID, orderID: orderID, onCompletion: onCompletion)
        case .deleteTracking(let siteID, let orderID, let trackingID, let onCompletion):
            deleteTracking(siteID: siteID, orderID: orderID, trackingID: trackingID, onCompletion: onCompletion)
        }
    }
}


// MARK: - Services!
//
private extension ShipmentStore {

    func synchronizeShipmentTrackingData(siteID: Int, orderID: Int, onCompletion: @escaping (Error?) -> Void) {
        let remote = ShipmentsRemote(network: network)
        remote.loadShipmentTrackings(for: siteID, orderID: orderID) { [weak self] (shipmentTrackingData, error) in
            guard let readOnlyShipmentTrackingData = shipmentTrackingData else {
                onCompletion(error)
                return
            }

            self?.upsertShipmentTrackingDataInBackground(siteID: siteID, orderID: orderID, readOnlyShipmentTrackingData: readOnlyShipmentTrackingData) {
                onCompletion(nil)
            }
        }
    }

    func syncronizeShipmentTrackingProviderGroupsData(siteID: Int, orderID: Int, onCompletion: @escaping (Error?) -> Void) {
        let remote = ShipmentsRemote(network: network)
        remote.loadShipmentTrackingProviderGroups(for: siteID, orderID: orderID) { [weak self] (groups, error) in
            guard let readOnlyShipmentTrackingProviderGroups = groups else {
                onCompletion(error)
                return
            }

            self?.upsertTrackingProviderDataInBackground(siteID: siteID,
                                                                 orderID: orderID,
                                                                 readOnlyShipmentTrackingProviderGroups: readOnlyShipmentTrackingProviderGroups,
                                                                 onCompletion: {
                onCompletion(nil)
            })
        }
    }

    func deleteTracking(siteID: Int, orderID: Int, trackingID: String, onCompletion: @escaping (Error?) -> Void) {
        let remote = ShipmentsRemote(network: network)
        remote.deleteShipmentTracking(for: siteID, orderID: orderID, trackingID: trackingID) { [weak self] (tracking, error) in
            guard let readOnlyTracking = tracking else {
                onCompletion(error)
                return
            }

            self?.deleteStoredShipment(siteID: siteID, orderID: orderID, trackingID: trackingID)
        }
    }
}


// MARK: - Persistence
//
extension ShipmentStore {

    /// Updates (OR Inserts) the specified ReadOnly ShipmentTracking Entities into the Storage Layer *in a background thread*. onCompletion will be called
    /// on the main thread!
    ///
    func upsertShipmentTrackingDataInBackground(siteID: Int,
                                                orderID: Int,
                                                readOnlyShipmentTrackingData: [Networking.ShipmentTracking],
                                                onCompletion: @escaping () -> Void) {
        let derivedStorage = sharedDerivedStorage
        derivedStorage.perform {
            for readOnlyTracking in readOnlyShipmentTrackingData {
                let storageTracking = derivedStorage.loadShipmentTracking(siteID: readOnlyTracking.siteID, orderID: readOnlyTracking.orderID,
                    trackingID: readOnlyTracking.trackingID) ?? derivedStorage.insertNewObject(ofType: Storage.ShipmentTracking.self)
                storageTracking.update(with: readOnlyTracking)
            }

            // Now, remove any objects that exist in storage but not in readOnlyShipmentTrackingData
            if let storageTrackings = derivedStorage.loadShipmentTrackingList(siteID: siteID,
                                                                              orderID: orderID) {
                storageTrackings.forEach({ storageTracking in
                    if readOnlyShipmentTrackingData.first(where: { $0.trackingID == storageTracking.trackingID } ) == nil {
                        derivedStorage.deleteObject(storageTracking)
                    }
                })
            }
        }

        storageManager.saveDerivedType(derivedStorage: derivedStorage) {
            DispatchQueue.main.async(execute: onCompletion)
        }
    }

    func upsertTrackingProviderData(siteID: Int, orderID: Int, readOnlyShipmentTrackingProviderGroups: [Networking.ShipmentTrackingProviderGroup]) {
        let storage = storageManager.viewStorage
        upsertShipmentTrackingGroups(siteID: siteID, readOnlyGroups: readOnlyShipmentTrackingProviderGroups, in: storage)
        storage.saveIfNeeded()
    }

    func upsertTrackingProviderDataInBackground(siteID: Int,
                                                orderID: Int,
                                                readOnlyShipmentTrackingProviderGroups: [Networking.ShipmentTrackingProviderGroup],
                                                onCompletion: @escaping () -> Void) {
        let derivedStorage = sharedDerivedStorage
        derivedStorage.perform {
            self.upsertShipmentTrackingGroups(siteID: siteID,
                                              readOnlyGroups: readOnlyShipmentTrackingProviderGroups,
                                              in: derivedStorage)
        }

        storageManager.saveDerivedType(derivedStorage: derivedStorage) {
            DispatchQueue.main.async(execute: onCompletion)
        }
    }

    private func upsertShipmentTrackingGroups(siteID: Int,
                                              readOnlyGroups: [Networking.ShipmentTrackingProviderGroup],
                                              in storage: StorageType) {
        for readOnlyGroup in readOnlyGroups {
            let storageGroup = storage.loadShipmentTrackingProviderGroup(siteID: siteID, providerGroupName: readOnlyGroup.name) ??
                storage.insertNewObject(ofType: Storage.ShipmentTrackingProviderGroup.self)

            storageGroup.update(with: readOnlyGroup)
            handleProviders(readOnlyGroup, storageGroup, storage)
        }

        // Now, remove any objects that exist in storage but not in readOnlyShipmentTrackingProviderGroups
        if let storageTrackingGroups = storage.loadShipmentTrackingProviderGroupList(siteID: siteID) {
            storageTrackingGroups.forEach({ storageTrackingGroup in
                if readOnlyGroups.first(where: { $0.name == storageTrackingGroup.name } ) == nil {
                    storage.deleteObject(storageTrackingGroup)
                }
            })
        }
    }

    /// Deletes any Storage.ShipmentTracking with the specified trackingID
    ///
    func deleteStoredShipment(siteID: Int,
                              orderID: Int,
                              trackingID: String) {
        let storage = storageManager.viewStorage
        guard let tracking = storage.loadShipmentTracking(siteID: siteID,
                                                          orderID: orderID,
                                                          trackingID: trackingID) else {
            return
        }

        storage.deleteObject(tracking)
        storage.saveIfNeeded()
    }

    private func handleProviders(_ readOnlyGroup: Networking.ShipmentTrackingProviderGroup,
                                      _ storageGroup: Storage.ShipmentTrackingProviderGroup,
                                      _ storage: StorageType) {
        // Upsert the items from the read-only group
        for readOnlyProvider in readOnlyGroup.providers {
            if let existingProvider = storage.loadShipmentTrackingProvider(siteID: readOnlyProvider.siteID,
                                                                           name: readOnlyProvider.name) {
                existingProvider.update(with: readOnlyProvider)
            } else {
                let newStorageProvider = storage.insertNewObject(ofType: Storage.ShipmentTrackingProvider.self)
                newStorageProvider.update(with: readOnlyProvider)
                storageGroup.addToProviders(newStorageProvider)
            }
        }

        // Now, remove any objects that exist in storageGroup.providers but not in readOnlyGroup.providers
        if let storageProviders = storageGroup.providers {
            storageProviders.forEach({ storageProvider in
                if readOnlyGroup.providers.first(where: { $0.name == storageProvider.name } ) == nil {
                    storageGroup.removeFromProviders(storageProvider)
                    storage.deleteObject(storageProvider)
                }
            })
        }
    }
}
