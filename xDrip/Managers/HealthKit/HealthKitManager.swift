import Foundation
import HealthKit
import os

public class HealthKitManager: NSObject {
    // MARK: - public properties
    
    // MARK: - private properties
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper: KeyValueObserverTimeKeeper = .init()
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryHealthKitManager)
    
    /// reference to coredatamanager
    private var coreDataManager: CoreDataManager
    
    /// reference to BgReadingsAccessor
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// is healthkit fully initiazed or not, that includes checking if healthkit is available, created successfully bloodGlucoseType, user authorized - value will get changed
    private var healthKitInitialized = false
    
    /// bloodGlucoseType - optional because if hk not available it can be initialized
    private var bloodGlucoseType: HKQuantityType?

    /// dietaryCarbohydrates type - optional because if hk not available it can not be initialized - used for the continuous carbs import
    private var carbsType: HKQuantityType?

    /// insulinDelivery type - optional because if hk not available it can not be initialized - used to write insulin treatments to HealthKit
    private var insulinType: HKQuantityType?

    /// reference to TreatmentEntryAccessor
    private var treatmentEntryAccessor: TreatmentEntryAccessor

    /// the currently running anchored object query used for the continuous carbs import, nil if not running
    private var carbsImportQuery: HKAnchoredObjectQuery?

    /// reference to HKHealthStore, should be used only if we're sure HealthKit is supported on the device
    private lazy var healthStore = HKHealthStore()

    /// set of timestamps currently being written to HealthKit to prevent overlap across runs
    private var timeStampsOfBgReadingsCurrentlyBeingSaved = Set<Date>()

    /// set of insulin treatment timestamps currently being written to HealthKit to prevent overlap across runs
    private var timeStampsOfInsulinTreatmentsCurrentlyBeingSaved = Set<Date>()

    /// true while a coalesced storeInsulinTreatments call is pending - avoids running a full store cycle for every single nightscoutTreatmentsUpdateCounter bump
    private var storeInsulinTreatmentsScheduled = false

    /// constant for key in ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground - restart the carbs import and store pending insulin treatments
    private let applicationManagerKeyRestartHealthKitSync = "HealthKitManager-RestartHealthKitSync"
    
    /// serial queue to ensure atomic updates of the latest HealthKit store timestamp
    /// the idea is to use this and force all updates to be done
    private let healthKitTimestampUpdateQueue = DispatchQueue(label: "HealthKitManager.timestampUpdate")
    
    // MARK: - intialization
    
    init(coreDataManager: CoreDataManager) {
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        treatmentEntryAccessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)

        // call super.init
        super.init()

        // listen for changes to userdefaults storeReadingsInHealthkitAuthorized
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue, options: .new, context: nil)
        // listen for changes to userdefaults storeReadingsInHealthkit
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue, options: .new, context: nil)
        // listen for changes to userdefaults importCarbsFromHealthKit, to start/stop the continuous carbs import
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.importCarbsFromHealthKit.rawValue, options: .new, context: nil)
        // listen for changes to userdefaults importInsulinFromDexcomShare, to store insulin treatments when the user enables the setting
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.importInsulinFromDexcomShare.rawValue, options: .new, context: nil)
        // listen for changes to userdefaults nightscoutTreatmentsUpdateCounter, so that newly added insulin treatments (Dexcom Share import, Nightscout download, manual entry) get written to HealthKit
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightscoutTreatmentsUpdateCounter.rawValue, options: .new, context: nil)

        // call initializeHealthKit, set healthKitInitialized according to result of initialization
        healthKitInitialized = initializeHealthKit()

        // do first store
        storeBgReadings()

        // start the continuous carbs import if enabled
        startOrStopCarbsImport()

        // store any insulin treatments not yet written to HealthKit
        storeInsulinTreatments()

        // when the app comes to the foreground, restart the carbs import (this heals a query that died, eg because it was executed before the user answered the authorization dialog) and store any pending insulin treatments
        ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground(key: applicationManagerKeyRestartHealthKitSync, closure: { [weak self] in
            self?.startOrStopCarbsImport()
            self?.storeInsulinTreatments()
        })
    }
    
    // MARK: - private functions
    
    /// checks if healthkit available, creates bloodGlucoseType, and checks if user authorized storing readings in healtkit
    /// - returns:
    ///     - result which indicates if initialize was successful or not, autorization request is done from within Settings views, when user enables HealthKit
    ///
    /// the return value of the function does not depend on UserDefaults.standard.storeReadingsInHealthkit - this setting needs to be verified each time there's  an new reading to store
    ///
    /// if authorizationStatus is notDetermined or sharingDenied, then UserDefaults.standard.storeReadingsInHealthkitAuthorized is set to false by this function
    private func initializeHealthKit() -> Bool {
        // if healthkit not available (ipad) then no further processing
        if !HKHealthStore.isHealthDataAvailable() {
            return false
        }
        
        // initialize bloodGlucoseType
        bloodGlucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)

        // initialize carbsType and insulinType - used by the carbs import and insulin store which have their own authorization checks, independent of the bg readings store
        carbsType = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)
        insulinType = HKObjectType.quantityType(forIdentifier: .insulinDelivery)

        // if bloodGlucseType not correctly initialized then result is false
        guard let bloodGlucoseType = bloodGlucoseType else { return false }
        
        // set value of UserDefaults storeReadingsInHealthkitAuthorized according to actual value in HealthKit Store
        // because user might have first authorized, then remove the authorization - if it's not authorized, then set storeReadingsInHealthkitAuthorized to false
        let authorizationStatus = healthStore.authorizationStatus(for: bloodGlucoseType)
        switch authorizationStatus {
        case .notDetermined, .sharingDenied:
            UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            return false
        case .sharingAuthorized:
            break
        @unknown default:
            trace("unknown authorizationstatus for healthkit - HealthKitManager.swift", log: log, category: ConstantsLog.categoryHealthKitManager, type: .error)
            UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            return false
        }
        
        // all checks ok , return true
        return true
    }
    
    /// stores latest readings in healthkit, only if HK supported, authorized, enabled in settings
    public func storeBgReadings() {
        // ensure this function runs on main thread because it accesses objects from the main managedObjectContext
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.storeBgReadings()
            }
            return
        }
        // healthkit setting must be on, and healthkit must be initialized successfully
        if !UserDefaults.standard.storeReadingsInHealthkit || !healthKitInitialized {
            return
        }
        
        // bloodGlucoseType should not be nil
        guard let bloodGlucoseType = bloodGlucoseType else { return }
        
        // snapshot of the latest saved timestamp (strict boundary) and in-flight timestamps (to avoid re-saving while previous saves are not completed)
        let strictLatestHealthKitStoredTimeStamp = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? Date.distantPast
        let timeStampsCurrentlyInFlight: Set<Date> = healthKitTimestampUpdateQueue.sync { timeStampsOfBgReadingsCurrentlyBeingSaved }
        
        // user setting to allow more frequent HealthKit writes (e.g. Libre 2 Direct 60-second cadence)
        let storeFrequentReadingsInHealthKit = UserDefaults.standard.storeFrequentReadingsInHealthKit
        
        // get readings to store, limit to 2016 = maximum 1 week - just to avoid a huge array is being returned here, applying minimumTimeBetweenTwoReadingsInMinutes filter
        let bgReadingsToStore = bgReadingsAccessor.getLatestBgReadings(limit: 2016, fromDate: UserDefaults.standard.timeStampLatestHealthKitStoreBgReading, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false).filter(minimumTimeBetweenTwoReadingsInMinutes: storeFrequentReadingsInHealthKit ? 0 : ConstantsHealthKit.minimiumTimeBetweenTwoReadingsInMinutes, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: UserDefaults.standard.timeStampLatestHealthKitStoreBgReading)
        
        let bgReadingsToStoreAfterApplyingStrictBoundaryAndInFlightExclusion = bgReadingsToStore.filter {
            let isAfterStrictBoundary = $0.timeStamp > strictLatestHealthKitStoredTimeStamp
            let respectsFrequentWriteSpacing = !storeFrequentReadingsInHealthKit || ($0.timeStamp.timeIntervalSince(strictLatestHealthKitStoredTimeStamp) > 50)
            let isNotInFlight = !timeStampsCurrentlyInFlight.contains($0.timeStamp)
            return isAfterStrictBoundary && respectsFrequentWriteSpacing && isNotInFlight
        }
        
        let bloodGlucoseUnit = HKUnit(from: "mg/dL")
        
        if bgReadingsToStoreAfterApplyingStrictBoundaryAndInFlightExclusion.count > 0 {
            for (_, bgReading) in bgReadingsToStoreAfterApplyingStrictBoundaryAndInFlightExclusion.enumerated().reversed() { // reversed order because the first element is the youngest
                let quantity = HKQuantity(unit: bloodGlucoseUnit, doubleValue: bgReading.calculatedValue)
                let sample = HKQuantitySample(type: bloodGlucoseType, quantity: quantity, start: bgReading.timeStamp, end: bgReading.timeStamp)
                
                // store the timestamp of the last reading to upload, here in the main thread, because we use a bgReading for it, which is retrieved in the main mangedObjectContext
                let timeStampLastReadingToUpload = bgReading.timeStamp
                
                // mark this timestamp as in-flight to avoid being selected by overlapping runs until completion
                healthKitTimestampUpdateQueue.sync {
                    _ = timeStampsOfBgReadingsCurrentlyBeingSaved.insert(timeStampLastReadingToUpload)
                }
                
                healthStore.save(sample, withCompletion: { [weak self]
                    (success: Bool, error: Error?) in
                        guard let self = self else { return }
                        if success {
                            // Prevent timestamp regression if HealthKit save completions return out of order
                            // This is to avoid duplicate entries as seen here: https://github.com/JohanDegraeve/xdripswift/issues/662#issuecomment-3352013175
                            self.healthKitTimestampUpdateQueue.async {
                                // remove from in-flight set first, then perform atomic, monotonic watermark update
                                self.timeStampsOfBgReadingsCurrentlyBeingSaved.remove(timeStampLastReadingToUpload)
                                
                                let existingTimeStampLatestHealthKitStoreBgReading = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? Date.distantPast
                                let newTimeStampLatestHealthKitStoreBgReading = max(existingTimeStampLatestHealthKitStoreBgReading, timeStampLastReadingToUpload)
                                UserDefaults.standard.timeStampLatestHealthKitStoreBgReading = newTimeStampLatestHealthKitStoreBgReading
                            }
                        } else if let error = error {
                            // ensure in-flight removal even on failure
                            self.healthKitTimestampUpdateQueue.async {
                                self.timeStampsOfBgReadingsCurrentlyBeingSaved.remove(timeStampLastReadingToUpload)
                            }
                            trace("failed store reading in healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                        }
                })
            }
        }
    }
    
    // MARK: - carbs import from HealthKit

    /// starts (or stops) the continuous carbs import from HealthKit, according to the value of UserDefaults.standard.importCarbsFromHealthKit
    ///
    /// uses a long-running HKAnchoredObjectQuery with a persisted anchor, so that every carb sample is imported exactly once and new samples keep arriving as long as the app is alive - this is what makes the import continuous instead of a one-shot import
    public func startOrStopCarbsImport() {
        // stop any currently running query first - it will be recreated below if the setting is enabled
        if let carbsImportQuery = carbsImportQuery {
            healthStore.stop(carbsImportQuery)
            self.carbsImportQuery = nil
        }

        // healthkit must be available and the setting must be enabled - carbsType is always initialized when healthkit is available
        guard HKHealthStore.isHealthDataAvailable(), UserDefaults.standard.importCarbsFromHealthKit, let carbsType = carbsType else { return }

        // restore the previously persisted anchor, if any - this ensures samples delivered before are not delivered again, even across app restarts
        var anchor: HKQueryAnchor?
        if let anchorData = UserDefaults.standard.healthKitCarbsQueryAnchor {
            anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: anchorData)
        }

        // limit the initial import (i.e. when there's no anchor yet) to a reasonable period, otherwise the full HealthKit carbs history would be imported
        let predicate = HKQuery.predicateForSamples(withStart: Date(timeIntervalSinceNow: -TimeInterval(days: ConstantsHealthKit.carbsImportMaxAgeInDays)), end: nil, options: [])

        let query = HKAnchoredObjectQuery(type: carbsType, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit, resultsHandler: { [weak self] _, samples, _, newAnchor, error in
            self?.processImportedCarbsSamples(samples: samples, newAnchor: newAnchor, error: error)
        })

        // the updateHandler is what keeps the import running - it's called by HealthKit whenever new carb samples are added while the query is active
        query.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            self?.processImportedCarbsSamples(samples: samples, newAnchor: newAnchor, error: error)
        }

        healthStore.execute(query)
        carbsImportQuery = query

        trace("carbs import from HealthKit started", log: log, category: ConstantsLog.categoryHealthKitManager, type: .info)
    }

    /// processes carb samples delivered by the anchored object query : creates TreatmentEntry instances for samples not yet known, saves them and persists the new anchor
    private func processImportedCarbsSamples(samples: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?) {
        if let error = error {
            trace("in processImportedCarbsSamples, error = %{public}@", log: log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
            return
        }

        // treatments must be created/fetched on the main thread because the main managedObjectContext is used
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // skip samples written by this app itself, to avoid any risk of an import/export loop
            let quantitySamples = (samples ?? []).compactMap { $0 as? HKQuantitySample }.filter { $0.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier }

            if !quantitySamples.isEmpty {
                let dedupeWindow = ConstantsHealthKit.carbsImportDedupeWindowInSeconds

                // one fetch spanning the whole batch, deduping happens in memory - the initial import can deliver a large batch and a fetch per sample would block the main thread
                let earliestSampleDate = quantitySamples.map { $0.startDate }.min() ?? Date()
                let latestSampleDate = quantitySamples.map { $0.startDate }.max() ?? Date()
                var existingTreatments = self.treatmentEntryAccessor.getTreatments(fromDate: earliestSampleDate.addingTimeInterval(-dedupeWindow), toDate: latestSampleDate.addingTimeInterval(dedupeWindow), on: self.coreDataManager.mainManagedObjectContext)

                var didAddTreatment = false

                for sample in quantitySamples {
                    let grams = sample.quantity.doubleValue(for: .gram())
                    guard grams > 0 else { continue }

                    // dedupe : skip if a carbs treatment with (almost) the same timestamp and amount already exists (e.g. the same entry already came in via Nightscout) - deleted treatments count as duplicates too, so an entry the user deliberately deleted is not resurrected
                    if existingTreatments.contains(where: { $0.treatmentType == .Carbs && abs($0.date.timeIntervalSince(sample.startDate)) <= dedupeWindow && abs($0.value - grams) < 0.5 }) { continue }

                    let treatmentEntry = TreatmentEntry(date: sample.startDate, value: grams, treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "Apple Health", nsManagedObjectContext: self.coreDataManager.mainManagedObjectContext)

                    // also dedupe against treatments created earlier in this same batch
                    existingTreatments.append(treatmentEntry)

                    didAddTreatment = true

                    trace("imported carbs treatment from HealthKit, timestamp = %{public}@, grams = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .info, sample.startDate.description, grams.description)
                }

                if didAddTreatment {
                    self.coreDataManager.saveChanges()

                    // trigger an update of the chart and the treatments list
                    UserDefaults.standard.nightscoutTreatmentsUpdateCounter = UserDefaults.standard.nightscoutTreatmentsUpdateCounter + 1
                }
            }

            // persist the new anchor only after the samples have been processed, so nothing is lost if the app is killed in between
            if let newAnchor = newAnchor, let anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                UserDefaults.standard.healthKitCarbsQueryAnchor = anchorData
            }
        }
    }

    // MARK: - insulin treatments store

    /// writes insulin treatments imported from Dexcom Share to HealthKit, only if the importInsulinFromDexcomShare setting is enabled and HealthKit sharing is authorized for insulin
    ///
    /// instead of a high-watermark (which would permanently skip backdated doses), this queries HealthKit for the insulin samples this app already wrote in a fixed lookback window and writes whichever treatments are missing - self-healing and safe for out-of-order arrivals
    public func storeInsulinTreatments() {
        // setting must be on and healthkit must be available - insulinType is always initialized when healthkit is available
        guard UserDefaults.standard.importInsulinFromDexcomShare, HKHealthStore.isHealthDataAvailable(), let insulinType = insulinType else { return }

        // sharing insulin data must be authorized
        guard healthStore.authorizationStatus(for: insulinType) == .sharingAuthorized else { return }

        let lookbackStartDate = Date(timeIntervalSinceNow: -TimeInterval(hours: ConstantsHealthKit.insulinStoreLookbackInHours))

        // find the insulin samples this app already wrote in the lookback window, then write the missing treatments
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [HKQuery.predicateForObjects(from: HKSource.default()), HKQuery.predicateForSamples(withStart: lookbackStartDate, end: nil, options: [])])

        let query = HKSampleQuery(sampleType: insulinType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil, resultsHandler: { [weak self] _, samples, error in
            guard let self = self else { return }

            if let error = error {
                trace("in storeInsulinTreatments, failed to query existing insulin samples, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                return
            }

            let existingSampleKeys = Set(((samples as? [HKQuantitySample]) ?? []).map { HealthKitManager.insulinSampleKey(date: $0.startDate, value: $0.quantity.doubleValue(for: .internationalUnit())) })

            // treatments must be fetched on the main thread because the main managedObjectContext is used
            DispatchQueue.main.async { [weak self] in
                self?.storeMissingInsulinTreatments(existingSampleKeys: existingSampleKeys, fromDate: lookbackStartDate, insulinType: insulinType)
            }
        })

        healthStore.execute(query)
    }

    /// writes the insulin treatments (imported from Dexcom Share) in the lookback window that don't have a matching HealthKit sample yet. Must be called on the main thread.
    private func storeMissingInsulinTreatments(existingSampleKeys: Set<String>, fromDate: Date, insulinType: HKQuantityType) {
        // snapshot of in-flight timestamps (to avoid re-saving while previous saves are not completed)
        let timeStampsCurrentlyInFlight: Set<Date> = healthKitTimestampUpdateQueue.sync { timeStampsOfInsulinTreatmentsCurrentlyBeingSaved }

        // only treatments imported from Dexcom Share are written - the setting is specifically about mirroring the insulin logged in the Dexcom app to Apple Health
        let insulinTreatmentsToStore = treatmentEntryAccessor.getTreatments(fromDate: fromDate, toDate: nil, on: coreDataManager.mainManagedObjectContext).filter {
            $0.treatmentType == .Insulin && !$0.treatmentdeleted && $0.value > 0
                && $0.enteredBy == ConstantsDexcomShare.dexcomShareEnteredBy
                && !timeStampsCurrentlyInFlight.contains($0.date)
                && !existingSampleKeys.contains(HealthKitManager.insulinSampleKey(date: $0.date, value: $0.value))
        }

        let insulinUnit = HKUnit.internationalUnit()

        for treatment in insulinTreatmentsToStore {
            let quantity = HKQuantity(unit: insulinUnit, doubleValue: treatment.value)
            let metadata: [String: Any] = [HKMetadataKeyInsulinDeliveryReason: HKInsulinDeliveryReason.bolus.rawValue]
            let sample = HKQuantitySample(type: insulinType, quantity: quantity, start: treatment.date, end: treatment.date, metadata: metadata)

            // store the timestamp here in the main thread, because we use a treatment for it, which is retrieved in the main managedObjectContext
            let timeStampOfTreatmentToStore = treatment.date

            // mark this timestamp as in-flight to avoid being selected by overlapping runs until completion
            healthKitTimestampUpdateQueue.sync {
                _ = timeStampsOfInsulinTreatmentsCurrentlyBeingSaved.insert(timeStampOfTreatmentToStore)
            }

            healthStore.save(sample, withCompletion: { [weak self] (success: Bool, error: Error?) in
                guard let self = self else { return }

                // once the save completed (successfully or not) the sample is either visible to the next HealthKit query or should be retried, so the in-flight marker can be removed
                self.healthKitTimestampUpdateQueue.async {
                    self.timeStampsOfInsulinTreatmentsCurrentlyBeingSaved.remove(timeStampOfTreatmentToStore)
                }

                if !success, let error = error {
                    trace("failed to store insulin treatment in healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                }
            })
        }
    }

    /// stable key identifying an insulin sample/treatment by second-rounded timestamp and hundredth-of-a-unit value - used to match treatments against samples already written to HealthKit
    private static func insulinSampleKey(date: Date, value: Double) -> String {
        return "\(Int(date.timeIntervalSince1970))-\(Int((value * 100).rounded()))"
    }

    /// coalesces multiple triggers into a single storeInsulinTreatments call one second later - the nightscoutTreatmentsUpdateCounter can bump several times during a sync cycle
    private func scheduleStoreInsulinTreatments() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.storeInsulinTreatmentsScheduled else { return }

            self.storeInsulinTreatmentsScheduled = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.storeInsulinTreatmentsScheduled = false
                self.storeInsulinTreatments()
            }
        }
    }

    // MARK: - observe function
    
    /// when UserDefaults storeReadingsInHealthkitAuthorized or storeReadingsInHealthkit changes, then reinitialize the property healthKitInitialized
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                switch keyPathEnum {
                case UserDefaults.Key.storeReadingsInHealthkitAuthorized, UserDefaults.Key.storeReadingsInHealthkit:

                    // check latest change, to avoid there's an endless loop, because initializeHealthKit is actually setting value of storeReadingsInHealthkitAuthorized
                    if keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 100) {
                        // doesn't matter which if the two settings got changed, it's ok to call initialize
                        healthKitInitialized = initializeHealthKit()

                        // doesn't matter which if the two settings got changed, it's ok to call initialize
                        storeBgReadings()
                    }

                case UserDefaults.Key.importCarbsFromHealthKit:

                    if keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 100) {
                        // start or stop the continuous carbs import according to the new value of the setting
                        startOrStopCarbsImport()
                    }

                case UserDefaults.Key.importInsulinFromDexcomShare:

                    if keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 100) {
                        // store insulin treatments not yet written to HealthKit, in case the user just enabled the setting
                        storeInsulinTreatments()
                    }

                case UserDefaults.Key.nightscoutTreatmentsUpdateCounter:

                    // treatments were added/updated (Dexcom Share insulin import, Nightscout download, manual entry, carbs import) - write any new insulin treatments to HealthKit, coalesced because the counter can bump several times in quick succession
                    scheduleStoreInsulinTreatments()

                default:
                    break
                }
            }
        }
    }
    
    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.importCarbsFromHealthKit.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.importInsulinFromDexcomShare.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.nightscoutTreatmentsUpdateCounter.rawValue)

        // stop the carbs import query if running
        if let carbsImportQuery = carbsImportQuery {
            healthStore.stop(carbsImportQuery)
        }

        ApplicationManager.shared.removeClosureToRunWhenAppWillEnterForeground(key: applicationManagerKeyRestartHealthKitSync)
    }
}
