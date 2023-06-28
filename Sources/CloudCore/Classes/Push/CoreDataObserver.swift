//
//  CoreDataChangesListener.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

/// Class responsible for taking action on Core Data changes
class CoreDataObserver {
	var persistentContainer: NSPersistentContainer
    var processContext: NSManagedObjectContext

	let converter = ObjectToRecordConverter()
	let pushOperationQueue = PushOperationQueue()
    
	static let pushContextName = "CloudCorePush"
	
    var processTimer: Timer?
    
    var isProcessing = false
    var processAgain = true
    
	// Used for errors delegation
	weak var delegate: CloudCoreDelegate?
	
    var isOnline = true {
        didSet {
            if isOnline != oldValue && isOnline == true {
                processPersistentHistory()
            }
        }
    }
    
    public init(persistentContainer: NSPersistentContainer, processContext: NSManagedObjectContext) {
		self.persistentContainer = persistentContainer
        self.processContext = processContext
        
		converter.errorBlock = { [weak self] in
			self?.delegate?.error(error: $0, module: .some(.pushToCloud))
		}
        
        var usePersistentHistoryForPush = false
        if let storeDescription = persistentContainer.persistentStoreDescriptions.first,
           let persistentHistoryNumber = storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber
        {
            usePersistentHistoryForPush = persistentHistoryNumber.boolValue
        }
        assert(usePersistentHistoryForPush)
        
        processPersistentHistory()
	}
	
	/// Observe Core Data willSave and didSave notifications
	func start() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.willSave(notification:)),
                                               name: .NSManagedObjectContextWillSave,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.didSave(notification:)),
                                               name: .NSManagedObjectContextDidSave,
                                               object: nil)        
	}
	
	/// Remove Core Data observers
	func stop() {
		NotificationCenter.default.removeObserver(self)        
	}
	
	deinit {
		stop()
	}
	
    func shouldProcess(_ context: NSManagedObjectContext) -> Bool {
        // Ignore saves that are generated by PullController
        if context.name != CloudCore.config.pushContextName { return false }
        
        // Upload only for changes in root context that will be saved to persistentStore
        if context.parent != nil { return false }
        
        return true
    }
    
    func processChanges() -> Bool {
        var success = true
        
        CloudCore.delegate?.willSyncToCloud()
        
        let backgroundContext = persistentContainer.newBackgroundContext()
        backgroundContext.name = CoreDataObserver.pushContextName
        backgroundContext.automaticallyMergesChangesFromParent = true
        
        let records = converter.processPendingOperations(in: backgroundContext)
        pushOperationQueue.errorBlock = {
            self.handle(error: $0, parentContext: backgroundContext)
            success = false
        }
        pushOperationQueue.addOperations(recordsToSave: records.recordsToSave, recordIDsToDelete: records.recordIDsToDelete)
        pushOperationQueue.waitUntilAllOperationsAreFinished()
        
        if success {
            backgroundContext.performAndWait {
                do {
                    if backgroundContext.hasChanges {
                        try backgroundContext.save()
                    }
                } catch {
                    delegate?.error(error: error, module: .some(.pushToCloud))
                    success = false
                }
            }
        }
        
        CloudCore.delegate?.didSyncToCloud()
        
        return success
    }
    
    func process(_ transaction: NSPersistentHistoryTransaction, in moc: NSManagedObjectContext) -> Bool {
        var success = true

        if transaction.contextName != CloudCore.config.pushContextName { return success }
        
        if let changes = transaction.changes {
            var insertedObjects = Set<NSManagedObject>()
            var updatedObject = Set<NSManagedObject>()
            var deletedRecordIDs: [RecordIDWithDatabase] = []
            var operationIDs: [String] = []
            
            for change in changes {
                switch change.changeType {
                case .insert:
                    if let inserted = try? moc.existingObject(with: change.changedObjectID) {
                        insertedObjects.insert(inserted)
                    }
                    
                case .update:
                    if let inserted = try? moc.existingObject(with: change.changedObjectID) {
                        if let updatedProperties = change.updatedProperties {
                            let updatedPropertyNames: [String] = updatedProperties.map { (propertyDescription) in
                                return propertyDescription.name
                            }
                            inserted.updatedPropertyNames = updatedPropertyNames
                        }
                        updatedObject.insert(inserted)
                    }
                    
                case .delete:
                    if change.tombstone != nil {
                        if let privateRecordData = change.tombstone!["privateRecordData"] as? Data {
                            let ckRecord = CKRecord(archivedData: privateRecordData)
                            let database = ckRecord?.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? CloudCore.config.container.privateCloudDatabase : CloudCore.config.container.sharedCloudDatabase
                            let recordIDWithDatabase = RecordIDWithDatabase((ckRecord?.recordID)!, database)
                            deletedRecordIDs.append(recordIDWithDatabase)
                        }
                        if let publicRecordData = change.tombstone!["publicRecordData"] as? Data {
                            let ckRecord = CKRecord(archivedData: publicRecordData)
                            let recordIDWithDatabase = RecordIDWithDatabase((ckRecord?.recordID)!, CloudCore.config.container.publicCloudDatabase)
                            deletedRecordIDs.append(recordIDWithDatabase)
                        }
                        if let operationID = change.tombstone!["operationID"] as? String {
                            operationIDs.append(operationID)
                        }
                    }
                    
                default:
                    break
                }
            }
            
            self.converter.prepareOperationsFor(inserted: insertedObjects,
                                                updated: updatedObject,
                                                deleted: deletedRecordIDs)
                                
            try? moc.save()
            
            if self.converter.hasPendingOperations {
                success = self.processChanges()
            }
            
            // check for cached assets
            if success == true {
                moc.perform {
                    for insertedObject in insertedObjects {
                        guard let cacheable = insertedObject as? CloudCoreCacheable,
                              cacheable.cacheState == .local
                        else { continue }
                        
                        cacheable.cacheState = .upload
                    }
                    
                    try? moc.save()
                }
            }
            
            if !operationIDs.isEmpty {
                CloudCore.cacheManager?.cancelOperations(with: operationIDs)
            }
        }
        
        return success
    }
    
    @objc func processPersistentHistory() {
        #if os(iOS)
        guard isOnline else { return }
        #endif
        
        if isProcessing {
            processAgain = true
            
            return
        }
        
        #if TARGET_OS_IOS
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CloudCore.processPersistentHistory")
        #endif
        
        isProcessing = true

        processContext.perform {
            let settings = UserDefaults.standard
            do {
                var token: NSPersistentHistoryToken? = nil
                if let data = settings.object(forKey: CloudCore.config.persistentHistoryTokenKey) as? Data {
                    token = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSPersistentHistoryToken.classForKeyedUnarchiver()], from: data) as? NSPersistentHistoryToken
                }
                let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                let historyResult = try self.processContext.execute(historyRequest) as! NSPersistentHistoryResult
                
                if let history = historyResult.result as? [NSPersistentHistoryTransaction] {
                    for transaction in history {
                        if self.process(transaction, in: self.processContext) {
                            let deleteRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: transaction)
                            try self.processContext.execute(deleteRequest)
                            
                            let data = try NSKeyedArchiver.archivedData(withRootObject: transaction.token, requiringSecureCoding: false)
                            settings.set(data, forKey: CloudCore.config.persistentHistoryTokenKey)
                        } else {
                            break
                        }
                    }
                }
            } catch {
                let nserror = error as NSError
                switch nserror.code {
                case NSPersistentHistoryTokenExpiredError:
                    settings.set(nil, forKey: CloudCore.config.persistentHistoryTokenKey)
                default:
                    fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
                }
            }
            
            #if TARGET_OS_IOS
            UIApplication.shared.endBackgroundTask(backgroundTask)
            #endif
            
            DispatchQueue.main.async {
                self.isProcessing = false
                
                if self.processAgain {
                    self.processAgain = false
                    
                    self.processPersistentHistory()
                }
            }
        }
    }
    
	@objc private func willSave(notification: Notification) {
		guard let context = notification.object as? NSManagedObjectContext else { return }
        guard shouldProcess(context) else { return }
        
        context.insertedObjects.forEach { (inserted) in
            if let serviceAttributeNames = inserted.entity.serviceAttributeNames {
                for scope in serviceAttributeNames.scopes {
                    let _ = try? inserted.setRecordInformation(for: scope)
                }
            }
        }
	}
	
	@objc private func didSave(notification: Notification) {
		guard let context = notification.object as? NSManagedObjectContext else { return }
        guard shouldProcess(context) else { return }
        
            // we've been asked to retry later
        if let date = CloudCore.pauseUntil,
            date.timeIntervalSinceNow > 0
        { return }
        
        DispatchQueue.main.async {
            self.processTimer?.invalidate()
            self.processTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                self.processPersistentHistory()
            }
        }
    }
    
	private func handle(error: Error, parentContext: NSManagedObjectContext) {
		guard let cloudError = error as? CKError else {
			delegate?.error(error: error, module: .some(.pushToCloud))
			return
		}

		switch cloudError.code {
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            pushOperationQueue.cancelAllOperations()
            
            if let number = cloudError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
                CloudCore.pauseUntil = Date(timeIntervalSinceNow: number.doubleValue)
            }
            
		// Zone was accidentally deleted (NOT PURGED), we need to reupload all data accroding Apple Guidelines
		case .zoneNotFound:
			pushOperationQueue.cancelAllOperations()
			
            var resetZoneOperations: [Operation] = []
            
            var deleteZoneOperation: Operation? = nil
            if let _ = cloudError.userInfo["CKErrorUserDidResetEncryptedDataKey"] {
                // per https://developer.apple.com/documentation/cloudkit/encrypting_user_data
                // see also https://github.com/apple/cloudkit-sample-encryption
                
                let deleteOp = DeleteCloudCoreZoneOperation()
                resetZoneOperations.append(deleteOp)
                
                deleteZoneOperation = deleteOp
            }
            
			// Create CloudCore Zone
			let createZoneOperation = CreateCloudCoreZoneOperation()
			createZoneOperation.errorBlock = {
				self.delegate?.error(error: $0, module: .some(.pushToCloud))
				self.pushOperationQueue.cancelAllOperations()
			}
            if let deleteZoneOperation {
                createZoneOperation.addDependency(deleteZoneOperation)
            }
            resetZoneOperations.append(createZoneOperation)
			
			// Subscribe operation
            let subscribeOperation = SubscribeOperation()
            subscribeOperation.errorBlock = { self.delegate?.error(error: $0, module: .some(.pushToCloud)) }
            subscribeOperation.addDependency(createZoneOperation)
            resetZoneOperations.append(subscribeOperation)
            
			// Upload all local data
			let uploadOperation = PushAllLocalDataOperation(parentContext: parentContext, managedObjectModel: persistentContainer.managedObjectModel)
			uploadOperation.errorBlock = { self.delegate?.error(error: $0, module: .some(.pushToCloud)) }
            uploadOperation.addDependency(createZoneOperation)
            resetZoneOperations.append(uploadOperation)
            
			pushOperationQueue.addOperations(resetZoneOperations, waitUntilFinished: true)
		case .operationCancelled: return
		default: delegate?.error(error: cloudError, module: .some(.pushToCloud))
		}
	}

}