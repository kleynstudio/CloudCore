//
//  PullOperation.swift
//  CloudCore
//
//  Created by deeje cooley on 3/23/21.
//

import CloudKit
import CoreData

public class PullOperation: Operation {
    
    internal let persistentContainer: NSPersistentContainer
    
    /// Called every time if error occurs
    public var errorBlock: ErrorBlock?
    
    internal let queue = OperationQueue()
    
    internal var fetchedRecordIDs: [CKRecord.ID] = []
    internal var objectsWithMissingReferences = [MissingReferences]()
    
    public init(persistentContainer: NSPersistentContainer) {
        self.persistentContainer = persistentContainer
        
        super.init()
        
        qualityOfService = .userInitiated
        
        queue.name = "PullQueue"
        queue.maxConcurrentOperationCount = 1
    }
    
    internal func addFetchRecordsOp(recordIDs: [CKRecord.ID], database: CKDatabase, backgroundContext: NSManagedObjectContext) {
        let fetchRecords = CKFetchRecordsOperation(recordIDs: recordIDs)
        fetchRecords.database = database
        fetchRecords.qualityOfService = .userInitiated
        fetchRecords.desiredKeys = persistentContainer.managedObjectModel.desiredKeys
        fetchRecords.perRecordCompletionBlock = { record, recordID, error in
            if let record {
                self.fetchedRecordIDs.append(recordID!)
                
                self.addConvertRecordOperation(record: record, context: backgroundContext)
                
                var childIDs: [CKRecord.ID] = []
                record.allKeys().forEach { key in
                    if let reference = record[key] as? CKRecord.Reference, !self.fetchedRecordIDs.contains(reference.recordID) {
                        childIDs.append(reference.recordID)
                    }
                    if let array = record[key] as? [CKRecord.Reference] {
                        array.forEach { reference in
                            if !self.fetchedRecordIDs.contains(reference.recordID) {
                                childIDs.append(reference.recordID)
                            }
                        }
                    }
                }
                
                if !childIDs.isEmpty {
                    self.addFetchRecordsOp(recordIDs: childIDs, database: database, backgroundContext: backgroundContext)
                }
            }
        }
        let finished = BlockOperation { }
        finished.addDependency(fetchRecords)
        database.add(fetchRecords)
        self.queue.addOperation(finished)
    }
    
    internal func addConvertRecordOperation(record: CKRecord, context: NSManagedObjectContext) {
        // Convert and write CKRecord To NSManagedObject Operation
        let convertOperation = RecordToCoreDataOperation(parentContext: context, record: record)
        convertOperation.errorBlock = { self.errorBlock?($0) }
        convertOperation.completionBlock = {
            context.performAndWait {
                self.objectsWithMissingReferences.append(convertOperation.missingObjectsPerEntities)
            }
        }
        self.queue.addOperation(convertOperation)
    }
    
    internal func processMissingReferences(context: NSManagedObjectContext) {
        // iterate over all missing references and fix them, now are all NSManagedObjects created
        context.performAndWait {
            for missingReferences in objectsWithMissingReferences {
                for (object, references) in missingReferences {
                    guard let serviceAttributes = object.entity.serviceAttributeNames else { continue }
                    
                    for (attributeName, recordNames) in references {
                        for recordName in recordNames {
                            guard let relationship = object.entity.relationshipsByName[attributeName], let targetEntityName = relationship.destinationEntity?.name else { continue }
                            
                            // TODO: move to extension
                            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: targetEntityName)
                            fetchRequest.predicate = NSPredicate(format: serviceAttributes.recordName + " == %@" , recordName)
                            fetchRequest.fetchLimit = 1
                            fetchRequest.includesPropertyValues = false
                            
                            do {
                                let foundObject = try context.fetch(fetchRequest).first as? NSManagedObject
                                
                                if let foundObject {
                                    if relationship.isToMany {
                                        let set = object.value(forKey: attributeName) as? NSMutableSet ?? NSMutableSet()
                                        set.add(foundObject)
                                        object.setValue(set, forKey: attributeName)
                                    } else {
                                        object.setValue(foundObject, forKey: attributeName)
                                    }
                                } else {
                                    print("warning: object not found " + recordName)
                                }
                            } catch {
                                self.errorBlock?(error)
                            }
                        }
                    }
                }
            }
        }
    }
    
}
