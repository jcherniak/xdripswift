import UIKit
import HealthKit
import os

fileprivate enum Setting: Int, CaseIterable {
    /// should we write data to Apple Health?
    case enabledHealthKit = 0

    /// should we continuously import carb entries from Apple Health?
    case importCarbsFromHealthKit = 1

    /// should we import insulin entries from Dexcom Share when in follower mode (and write them to Apple Health)?
    case importInsulinFromDexcomShare = 2
}

/// conforms to SettingsViewModelProtocol for all healthkit settings in the first sections screen
class SettingsViewHealthKitSettingsViewModel:SettingsViewModelProtocol {
    
    // MARK: - private properties
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryHealthKitManager)
    
    // MARK: - functions in protocol SettingsViewModelProtocol
    
    func storeRowReloadClosure(rowReloadClosure: ((Int) -> Void)) {}
    
    func storeUIViewController(uIViewController: UIViewController) {}
    
    func storeMessageHandler(messageHandler: ((String, String) -> Void)) {
        // this ViewModel does need to send back messages to the viewcontroller asynchronously
    }
    
    func completeSettingsViewRefreshNeeded(index: Int) -> Bool {
        return false
    }
    
    func isEnabled(index: Int) -> Bool {
        // if healthkit not available (iPad) then don't enable
        return HKHealthStore.isHealthDataAvailable()
    }
    
    func onRowSelect(index: Int) -> SettingsSelectedRowAction {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }

        switch setting {
        case .enabledHealthKit, .importCarbsFromHealthKit, .importInsulinFromDexcomShare:
            return .nothing
        }
    }
    
    func sectionTitle() -> String? {
        return ConstantsSettingsIcons.healthKitSettingsIcon + " " + Texts_SettingsView.sectionTitleHealthKit
    }
    
    func numberOfRows() -> Int {
        return Setting.allCases.count
    }
    
    func settingsRowText(index: Int) -> String {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }

        switch setting {
        case .enabledHealthKit:
            return Texts_SettingsView.labelHealthKit
        case .importCarbsFromHealthKit:
            return Texts_SettingsView.labelImportCarbsFromHealthKit
        case .importInsulinFromDexcomShare:
            return Texts_SettingsView.labelImportInsulinFromDexcomShare
        }
    }

    func accessoryType(index: Int) -> UITableViewCell.AccessoryType {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }

        switch setting {
        case .enabledHealthKit, .importCarbsFromHealthKit, .importInsulinFromDexcomShare:
            return .none
        }
    }

    func detailedText(index: Int) -> String? {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }

        switch setting {
        case .enabledHealthKit, .importCarbsFromHealthKit, .importInsulinFromDexcomShare:
            return nil
        }
    }
    
    func uiView(index:Int) -> UIView? {
        
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }
        
        switch setting {
        case .enabledHealthKit:
            return UISwitch(isOn: UserDefaults.standard.storeReadingsInHealthkit, action: {
                (isOn: Bool) in                
                trace("storeReadingsInHealthkit changed by user to %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .info, isOn.description)
                
                // if value change to on, then verify authorization status and if needed ask authorization
                if isOn {
                    
                    // if creation of bloodGlucoseType fails, then we result in an inconsistent situation
                    if let bloodGlucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) {
                        let healthStore = HKHealthStore()
                        let authorizationStatus = healthStore.authorizationStatus(for: bloodGlucoseType)
                        switch authorizationStatus {
                            
                        case .notDetermined:
                            var shareTypes = Set<HKSampleType>()
                            shareTypes.insert(bloodGlucoseType)
                            healthStore.requestAuthorization(toShare: shareTypes, read: nil, completion: { (success:Bool, error:Error?) in
                                
                                UserDefaults.standard.storeReadingsInHealthkitAuthorized = success
                                
                                if let error = error {
                                    trace("user did not authorize to store bg readings in  healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error, error.localizedDescription)
                                }
                            })
                        case .sharingDenied:
                            UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
                            // user must have removed the authorization in the healt app - when user tries to enable healthkit , user will not be informed that he should first go back to the healt app and allow upload bgreadings - let's do such info in a later phase, eg with an info button next to the setting
                            trace("user removed authorization to store bgreadings in healthkit", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                        case .sharingAuthorized:
                            break
                        @unknown default:
                            trace("unknown authorizationstatus for healthkit - SettingsViewHealthKitSettingsViewModel", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                        }
                    } else {
                        trace("user enabled HealthKit however failed to create bloodGlucoseType", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                        return
                    }
                    
                }
                
                // set UserDefaults.standard.storeReadingsInHealthkit to isOn
                UserDefaults.standard.storeReadingsInHealthkit = isOn

            })

        case .importCarbsFromHealthKit:
            return UISwitch(isOn: UserDefaults.standard.importCarbsFromHealthKit, action: {
                (isOn: Bool) in
                trace("importCarbsFromHealthKit changed by user to %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .info, isOn.description)

                // if value changed to on, then ask authorization to read carb entries - if authorization was already determined (granted or denied) then this doesn't show any UI.
                // the setting is only stored once the authorization request has resolved, so that the HealthKitManager (which observes the setting) doesn't execute its query while the authorization dialog is still open
                if isOn, let carbsType = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates) {
                    HKHealthStore().requestAuthorization(toShare: nil, read: Set([carbsType]), completion: { (success: Bool, error: Error?) in
                        if let error = error {
                            trace("failed to request authorization to read carb entries from healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error, error.localizedDescription)
                        }

                        DispatchQueue.main.async {
                            // set UserDefaults.standard.importCarbsFromHealthKit - the HealthKitManager observes this setting and will start the continuous import
                            UserDefaults.standard.importCarbsFromHealthKit = true
                        }
                    })
                } else {
                    UserDefaults.standard.importCarbsFromHealthKit = isOn
                }

            })

        case .importInsulinFromDexcomShare:
            return UISwitch(isOn: UserDefaults.standard.importInsulinFromDexcomShare, action: {
                (isOn: Bool) in
                trace("importInsulinFromDexcomShare changed by user to %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .info, isOn.description)

                // if value changed to on, then ask authorization to write insulin entries - if authorization was already determined (granted or denied) then this doesn't show any UI.
                // the setting is only stored once the authorization request has resolved, so that the managers observing it don't run while the authorization dialog is still open
                if isOn, let insulinType = HKObjectType.quantityType(forIdentifier: .insulinDelivery) {
                    HKHealthStore().requestAuthorization(toShare: Set([insulinType]), read: nil, completion: { (success: Bool, error: Error?) in
                        if let error = error {
                            trace("failed to request authorization to write insulin entries to healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error, error.localizedDescription)
                        }

                        DispatchQueue.main.async {
                            // set UserDefaults.standard.importInsulinFromDexcomShare - the DexcomShareFollowManager and HealthKitManager observe this setting
                            UserDefaults.standard.importInsulinFromDexcomShare = true
                        }
                    })
                } else {
                    UserDefaults.standard.importInsulinFromDexcomShare = isOn
                }

            })
        }
    }
}


