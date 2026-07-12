//
//  DexcomShareFollowManager.swift
//  xdrip
//
//  Created by Paul Plant on 4/9/25.
//  Copyright © 2025 Johan Degraeve. All rights reserved.
//

import AudioToolbox
import AVFoundation
import CryptoKit
import Foundation
import os

/// instance of this class will do the follower functionality. Just make an instance, it will listen to the settings, do the regular download if needed - it could be deallocated when isMaster setting in Userdefaults changes, but that's not necessary to do
class DexcomShareFollowManager: NSObject {
    // MARK: - public properties
    
    // MARK: - private properties

    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper: KeyValueObserverTimeKeeper = .init()
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryDexcomShareFollowManager)
    
    /// reference to coredatamanager
    private var coreDataManager: CoreDataManager
    
    /// reference to BgReadingsAccessor
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// delegate to pass back glucosedata
    private(set) weak var followerDelegate: FollowerDelegate?
    
    /// AVAudioPlayer to use
    private var audioPlayer: AVAudioPlayer?
    
    /// constant for key in ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground - create playsoundtimer
    private let applicationManagerKeyResumePlaySoundTimer = "DexcomShareFollowerManager-ResumePlaySoundTimer"
    
    /// constant for key in ApplicationManager.shared.addClosureToRunWhenAppDidEnterBackground - invalidate playsoundtimer
    private let applicationManagerKeySuspendPlaySoundTimer = "DexcomShareFollowerManager-SuspendPlaySoundTimer"
    
    /// closure to call when downloadtimer needs to be invalidated, eg when changing from master to follower
    private var invalidateDownLoadTimerClosure: (() -> Void)?
    
    /// timer for playsound
    private var playSoundTimer: RepeatingTimer?
    
    private var dexcomShareSessionId: String?

    /// the accountId returned by the authentication step - needed to build the signed request used by the events endpoint
    private var dexcomShareAccountId: String?

    /// reference to TreatmentEntryAccessor - used to dedupe insulin treatments imported from Dexcom Share
    private var treatmentEntryAccessor: TreatmentEntryAccessor

    /// timestamp of the last attempt to fetch events (insulin) from Dexcom Share - used to throttle the events fetch
    private var timeStampLastEventsFetchAttempt: Date?

    /// how many times the events fetch has failed since the last success - used to avoid spamming the trace log
    private var eventsFetchFailedCount = 0

    /// timestamp of last received reading. Used to scale the maxCount size when requesting data from Dexcom Share
    private var timeStampLastBgReading: Date?
    
    // MARK: - initializer/de-initializer
    
    /// initializes a new DexcomShareFollowManager instance.
    /// - Parameters:
    ///     - coreDataManager: The CoreDataManager instance for BG reading storage.
    ///     - followerDelegate: The delegate to receive BG reading updates.
    public init(coreDataManager: CoreDataManager, followerDelegate: FollowerDelegate) {
        // clear failed login timestamp on init to always immediately allow a new login attempt
        UserDefaults.standard.dexcomShareLoginFailedTimestamp = nil
        
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        self.treatmentEntryAccessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)
        self.followerDelegate = followerDelegate
        
        // initialize the sessionId
        self.dexcomShareSessionId = nil
        self.timeStampLastBgReading = nil
        trace("Session ID cleared on init", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
        
        // set up audioplayer
        if let url = Bundle.main.url(forResource: ConstantsSuspensionPrevention.soundFileName, withExtension: "") {
            // create audioplayer
            do {
                self.audioPlayer = try AVAudioPlayer(contentsOf: url)
                
            } catch {
                trace("in init, exception while trying to create audoplayer, error = %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .error, error.localizedDescription)
            }
        }
        
        // call super.init
        super.init()
        
        // add observers
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.isMaster.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.followerDataSourceType.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.dexcomShareAccountName.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.dexcomSharePassword.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.importInsulinFromDexcomShare.rawValue, options: .new, context: nil)

        self.verifyUserDefaultsAndStartOrStopFollowMode()
    }
    
    /// Deinitializer. Removes observers, disables suspension prevention, and invalidates timers.
    deinit {
        // remove UserDefaults observers to avoid KVO crashes
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.isMaster.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.followerDataSourceType.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.dexcomShareAccountName.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.dexcomSharePassword.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.importInsulinFromDexcomShare.rawValue)

        // stop keep-alive helpers
        self.disableSuspensionPrevention()
        
        // invalidate any pending download timer
        self.invalidateDownLoadTimerClosure?()
    }
    
    // MARK: - public functions
    
    /// Creates a BgReading object from a FollowerBgReading (Dexcom Share download).
    /// - Parameters
    ///     - followGlucoseData: The glucose data from Dexcom Share.
    /// - Returns: A new BgReading (not saved in Core Data).
    public func createBgReading(followGlucoseData: FollowerBgReading) -> BgReading {
        // Trace creation of BgReading
        trace("Creating BgReading for timestamp: %{public}@, sgv: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, String(describing: followGlucoseData.timeStamp), String(describing: followGlucoseData.sgv))
        // set the device name in the BG Reading, especially useful for later uploading the Nightscout
        let deviceName = ConstantsHomeView.applicationName + " (Dexcom Share)"
        
        // create new bgReading
        let bgReading = BgReading(timeStamp: followGlucoseData.timeStamp, sensor: nil, calibration: nil, rawData: followGlucoseData.sgv, deviceName: deviceName, nsManagedObjectContext: self.coreDataManager.mainManagedObjectContext)
        
        // set calculatedValue
        bgReading.calculatedValue = followGlucoseData.sgv
        
        // set calculatedValueSlope
        let (calculatedValueSlope, hideSlope) = self.findSlope()
        bgReading.calculatedValueSlope = calculatedValueSlope
        bgReading.hideSlope = hideSlope
        
        return bgReading
    }
    
    // MARK: - private functions
    
    /// Calculates the slope and whether to hide it based on the last two BG readings.
    /// - Returns: Tuple of (slope value, hideSlope flag).
    private func findSlope() -> (calculatedValueSlope: Double, hideSlope: Bool) {
        // init returnvalues
        var hideSlope = true
        var calculatedValueSlope = 0.0
        
        // get last readings
        let last2Readings = self.bgReadingsAccessor.getLatestBgReadings(limit: 3, howOld: 1, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        
        // if more thant 2 readings, calculate slope and hie
        if last2Readings.count >= 2 {
            let (slope, hide) = last2Readings[0].calculateSlope(lastBgReading: last2Readings[1])
            calculatedValueSlope = slope
            hideSlope = hide
        }
        
        return (calculatedValueSlope, hideSlope)
    }
    
    /// Schedule new download with timer, when timer expires download() will be called
    private func scheduleNewDownload() {
        guard UserDefaults.standard.followerBackgroundKeepAliveType != .heartbeat else { return }
        
        // invalidate any previously scheduled download timer before creating a new one
        if let invalidateDownLoadTimerClosure = invalidateDownLoadTimerClosure {
            invalidateDownLoadTimerClosure()
            self.invalidateDownLoadTimerClosure = nil
        }
        
        trace("in scheduleNewDownload", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
        
        // schedule a timer for 60 seconds and assign it to a let property
        let downloadTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(self.download), userInfo: nil, repeats: false)
        
        // assign invalidateDownLoadTimerClosure to a closure that will invalidate the downloadTimer
        self.invalidateDownLoadTimerClosure = {
            downloadTimer.invalidate()
        }
    }
    
    /// Downloads recent readings from Dexcom Share, sends result to delegate, and schedules the next download.
    @objc public func download() {
        trace("in download. Current session ID: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, String(describing: self.dexcomShareSessionId))
        
        if (UserDefaults.standard.timeStampLatestNightscoutSyncRequest ?? .distantPast).timeIntervalSinceNow < -15 {
            trace("    setting nightscoutSyncRequired to true, this will also initiate a treatments/devicestatus sync", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
            UserDefaults.standard.timeStampLatestNightscoutSyncRequest = .now
            UserDefaults.standard.nightscoutSyncRequired = true
        }
        guard !UserDefaults.standard.isMaster else {
            trace("    not follower, returning", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
            return
        }
        guard UserDefaults.standard.followerDataSourceType == .dexcomShare else {
            trace("    followerDataSourceType is not Dexcom Share", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
            return
        }
        
        let username = UserDefaults.standard.dexcomShareAccountName
        let password = UserDefaults.standard.dexcomSharePassword
        guard let username, let password else {
            return
        }
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                // try and download, if it returns nil it's because we need to login
                if (try? await self.downloadAndProcessEGVs(force: true)) == nil {
                    try await self.login(username: username, password: password)
                    _ = try await self.downloadAndProcessEGVs(force: true) // ignore returned array here; delegate call happens inside
                }
            } catch DexcomShareFollowError.sessionExpired {
                // re-login once and retry on expired session
                trace("    in download, session expired, re-logging in", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .info)
                do {
                    try await self.login(username: username, password: password)
                    _ = try await self.downloadAndProcessEGVs(force: true)
                } catch {
                    trace("    in download, session expired and re-login failed: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .error, error.localizedDescription)
                }
            } catch {
                trace("    in download, error = %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .error, error.localizedDescription)
            }

            // if enabled, also try to import insulin events logged in the Dexcom app - failures are handled (and throttled) inside the function and never disturb the glucose download
            await self.downloadAndProcessInsulinEvents()

            // rescheduling the timer must be done on the main actor
            // we do it here at the end of the function so that it is always rescheduled once a valid connection is established, irrespective of whether we get values.
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // schedule new download
                self.scheduleNewDownload()
            }
        }
    }
    
    /// Attempts login for the Dexcom Share account, trying all regions if necessary.
    /// - Parameters:
    ///     - username: Dexcom Share account username
    ///     - password: Dexcom Share account password
    /// - Throws: DexcomShareFollowError if login fails for all regions
    private func login(username: String, password: String) async throws {
        // If a region is already stored, try only that region
        let storedRegion = UserDefaults.standard.dexcomShareRegion
        if storedRegion != .none {
            do {
                try await self.loginToRegion(region: storedRegion, username: username, password: password)
                trace("    in login, login successful using stored region: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, storedRegion.description)
                return
            } catch {
                trace("    in login, login failed using stored region: %{public}@, trying again with the other regions. Error: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, storedRegion.description, error.localizedDescription)
            }
        } else {
            trace("    in login, no previous stored DexcomShareRegion was found", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
        }
        
        // persist the error so that we can use it outside of the for loop
        var lastError: Error = DexcomShareFollowError.loginFailed
        
        // The stored region didn't work or there wasn't one stored, so try the other
        // regions (except the one we just tried) in order until one succeeds
        for region in DexcomShareRegion.allCases {
            if region != .none && region != storedRegion {
                trace("    in login, attempting login to region: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, region.description)
                do {
                    try await self.loginToRegion(region: region, username: username, password: password)
                    // On success, store the working region and clear the timestamp
                    UserDefaults.standard.dexcomShareRegion = region
                    UserDefaults.standard.dexcomShareLoginFailedTimestamp = nil
                    trace("    in login, login succeeded to region: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, region.description)
                    return
                } catch {
                    trace("    in login, login failed for region: %{public}@, error: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, region.description, error.localizedDescription)
                    lastError = error
                }
            }
        }
        
        // If all fail, clear the region and set loginFailedTimestamp
        UserDefaults.standard.dexcomShareRegion = .none
        UserDefaults.standard.dexcomShareLoginFailedTimestamp = Date()
        trace("    in login, all region login attempts failed, setting loginFailedTimestamp. Error: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, lastError.localizedDescription)
        throw lastError
    }
    
    /// Attempts login for a specific Dexcom Share region. Called from the main login() function.
    /// 2-step login process as per https://github.com/LoopKit/dexcom-share-client-swift/blob/dev/ShareClient/ShareClient.swift
    /// - Parameters:
    ///     - region: The DexcomShareRegion to try
    ///     - username: Dexcom Share account username
    ///     - password: Dexcom Share account password
    /// - Throws: DexcomShareFollowError if login fails for this region
    private func loginToRegion(region: DexcomShareRegion, username: String, password: String) async throws {
        // Step 1/2 - AUTH: Authenticate to get accountId
        var authRequest = URLRequest(url: region.baseURL.appendingPathComponent(ConstantsDexcomShare.dexcomShareFollowAuthPath))
        authRequest.httpMethod = "POST"
        authRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        authRequest.addValue("Dexcom%20Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0", forHTTPHeaderField: "User-Agent")
        
        let authBody: [String: String] = ["accountName": username, "password": password, "applicationId": region.applicationID]
        authRequest.httpBody = try JSONSerialization.data(withJSONObject: authBody, options: [])
        
        let (authData, authResponse) = try await URLSession.shared.data(for: authRequest)
        let authStatusCode = (authResponse as? HTTPURLResponse)?.statusCode ?? 0
        
        if authStatusCode >= 400 {
            throw DexcomShareFollowError.authFailed
        }
        
        let accountId = (String(data: authData, encoding: .utf8) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if accountId.isEmpty {
            throw DexcomShareFollowError.authFailed
        }

        // keep the accountId, it's needed to build the signed request used by the events (insulin) endpoint
        self.dexcomShareAccountId = accountId
        
        // Step 2/2 - LOGIN: Login by accountId
        var loginRequest = URLRequest(url: region.baseURL.appendingPathComponent(ConstantsDexcomShare.dexcomShareFollowLoginPath))
        loginRequest.httpMethod = "POST"
        loginRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.addValue("Dexcom%20Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0", forHTTPHeaderField: "User-Agent")
        
        let loginBody: [String: String] = ["accountId": accountId, "password": password, "applicationId": region.applicationID]
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: loginBody, options: [])
        
        let (loginData, loginResponse) = try await URLSession.shared.data(for: loginRequest)
        let loginStatusCode = (loginResponse as? HTTPURLResponse)?.statusCode ?? 0
        
        if loginStatusCode >= 400 {
            throw DexcomShareFollowError.loginFailed
        }

        // the server can accept the accountId, return status 200 but with a dummy/failed session ID of "00000000-..."
        // so we need to check for this and if we found it, treat it also as a failed login.
        let sessionId = (String(data: loginData, encoding: .utf8) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if sessionId.isEmpty || sessionId == ConstantsDexcomShare.failedSessionId {
            throw DexcomShareFollowError.loginFailed
        }
        
        // we're now sucessfully logged in, so set the sessionId
        self.dexcomShareSessionId = sessionId
    }
    
    /// Downloads and processes EGVs (glucose values) from Dexcom Share.
    /// - Parameters
    ///     - force: if true, bypasses the recent failed login timestamp check and always fetches
    /// - Returns: Array of DexcomEGV or nil if login is required
    /// - Throws: DexcomShareFollowError on error
    private func downloadAndProcessEGVs(force: Bool = false) async throws -> [DexcomEGV]? {
        // let's check and adjust the minimum data we need to request,
        // there's no reason the hammer the servers for no reason
        
        // use the last 24 hours as maximum as per the community documentation
        let minutesBackMax = 24 * 60
        let maxCountMax = minutesBackMax / 5
        
        // set the default as just getting the last reading in the last 6 minutes
        var minutesBack = 6
        var maxCount = 1
        
        // using the snapshot method for thread-safety
        if let lastBgReading = bgReadingsAccessor.lastSnapshot(forSensor: nil) {
            let minutesSinceLastBgReading = Int((Date().timeIntervalSince1970 - lastBgReading.timeStamp.timeIntervalSince1970) / 60)
            
            if !force {
                guard minutesSinceLastBgReading >= 5 else {
                    trace("    in downloadAndProcessEGVs, last BG reading was %{public}@ minute(s) ago -> aborting fetch", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, minutesSinceLastBgReading)
                    return []
                }
            }
            
            // if more than 5 minutes since last reading, let's adjust the fetch window
            if minutesSinceLastBgReading > 9 {
                minutesBack = minutesSinceLastBgReading
                // with one reading every 5 minutes, cap at 24 hours (288 readings)
                maxCount = min(minutesSinceLastBgReading / 5, maxCountMax)
                trace("    in downloadAndProcessEGVs, last BG reading was %{public}@ minutes ago. Widening window to request %{public}@ previous readings to backfill", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, minutesSinceLastBgReading, maxCount)
            } else {
                trace("    in downloadAndProcessEGVs, no changes made, just going to pull the last %{public}@ readings", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, maxCount)
            }
        } else {
            // this will only usually happen if no BG readings are in core data,
            // in this case, let's just fetch 24 hours worth
            minutesBack = minutesBackMax
            maxCount = maxCountMax
            trace("    in downloadAndProcessEGVs, no previous BG values so will fetch 24 hours of data", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
            trace("    in downloadAndProcessEGVs,no data found, pulling 24 hours", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug)
        }
        
        do {
            // try and fetch values based upon the number of "missing" readings since the last succesful fetch
            // this will usually not need adjusting and we'll just request the last 1 reading
            let glucoseMeasurementsArray = try await downloadLatestEGVs(minutes: minutesBack, maxCount: maxCount)
            
            // if no data is returned, do nothing
            if glucoseMeasurementsArray.isEmpty {
                return []
            }
            
            var followGlucoseDataArray: [FollowerBgReading] = []
            followGlucoseDataArray.reserveCapacity(glucoseMeasurementsArray.count)
            for glucoseMeasurement in glucoseMeasurementsArray {
                guard let timeStamp = parseDexcomDate(dexcomDateString: glucoseMeasurement.ST)?.timeIntervalSince1970 ?? parseDexcomDate(dexcomDateString: glucoseMeasurement.DT)?.timeIntervalSince1970 else { continue }
                
                let sgv = Double(glucoseMeasurement.Value)
                
                let bgReading = FollowerBgReading(timeStamp: Date(timeIntervalSince1970: timeStamp), sgv: sgv)
                
                followGlucoseDataArray.append(bgReading)
            }
            
            // sort by newest first
            followGlucoseDataArray.sort { $0.timeStamp > $1.timeStamp }
            // Dispatch to delegate on the main actor (use a local copy for the inout parameter)
            let localCopy = followGlucoseDataArray
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // call delegate followerInfoReceived which will process the new readings
                if let followerDelegate = self.followerDelegate {
                    var array = localCopy
                    followerDelegate.followerInfoReceived(followGlucoseDataArray: &array)
                }
            }
            return glucoseMeasurementsArray
        } catch let error as NSError where error.code == 401 {
            throw DexcomShareFollowError.invalidCredentials
        }
    }
    
    /// Downloads the latest EGVs from Dexcom Share for the given time window and count.
    /// - Parameters:
    ///     - minutes: how many minutes back to fetch.
    ///     - maxCount: maximum number of readings to fetch.
    /// - Returns: array of DexcomEGV.
    /// - Throws: DexcomShareFollowError on error.
    private func downloadLatestEGVs(minutes: Int = 1440, maxCount: Int = 3) async throws -> [DexcomEGV] {
        guard let dexcomShareSessionId else { throw DexcomShareFollowError.noSessionID }
        guard UserDefaults.standard.dexcomShareRegion != .none else { throw DexcomShareFollowError.noRegion }
        
        let region = UserDefaults.standard.dexcomShareRegion
        
        guard let componentsInitial = URLComponents(url: region.baseURL.appendingPathComponent(ConstantsDexcomShare.dexcomShareFollowLatestGlucoseValuesPath), resolvingAgainstBaseURL: false) else { throw DexcomShareFollowError.urlError }
        var components = componentsInitial
        
        components.queryItems = [
            .init(name: "sessionId", value: dexcomShareSessionId),
            .init(name: "minutes", value: String(minutes)),
            .init(name: "maxCount", value: String(maxCount))
        ]
        
        guard let url = components.url else { throw DexcomShareFollowError.urlError }
        var request = URLRequest(url: url)
        
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Dexcom Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data() // POST with empty body per community examples
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            self.dexcomShareSessionId = nil
            throw DexcomShareFollowError.sessionExpired
        }
        
        // store the current timestamp as a successful server connection
        UserDefaults.standard.timeStampOfLastFollowerConnection = Date()
        
        do {
            return try JSONDecoder().decode([DexcomEGV].self, from: data)
        } catch {
            throw error
        }
    }
    
    // MARK: - insulin events import

    /// Downloads events (insulin) from Dexcom Share and stores new insulin entries as treatments.
    /// Only runs if the importInsulinFromDexcomShare setting is enabled and we're in Dexcom Share follower mode.
    /// Attempts are throttled and failures never disturb the glucose download.
    private func downloadAndProcessInsulinEvents() async {
        // setting must be enabled and we must be in dexcom share follower mode with a valid session
        guard UserDefaults.standard.importInsulinFromDexcomShare else { return }
        guard !UserDefaults.standard.isMaster, UserDefaults.standard.followerDataSourceType == .dexcomShare else { return }
        guard let dexcomShareSessionId = self.dexcomShareSessionId, UserDefaults.standard.dexcomShareRegion != .none else { return }

        // throttle the events fetch - insulin events are logged only occasionally, no need to hammer the server every minute
        if let timeStampLastEventsFetchAttempt = timeStampLastEventsFetchAttempt, Date().timeIntervalSince(timeStampLastEventsFetchAttempt) < ConstantsDexcomShare.dexcomShareEventsFetchIntervalInSeconds {
            return
        }
        timeStampLastEventsFetchAttempt = Date()

        do {
            let insulinEvents = try await downloadLatestEvents(sessionId: dexcomShareSessionId)

            // reset the failure counter on success
            eventsFetchFailedCount = 0

            guard !insulinEvents.isEmpty else { return }

            // treatments must be created on the main thread because the main managedObjectContext is used
            await MainActor.run { [weak self] in
                self?.processInsulinEvents(insulinEvents)
            }
        } catch {
            // log the first failure as error, subsequent failures as debug to avoid filling the trace log -
            // the events endpoint requires a device-key signed request and Dexcom may reject our best-effort signature (see downloadLatestEvents)
            eventsFetchFailedCount += 1
            if eventsFetchFailedCount == 1 {
                trace("    in downloadAndProcessInsulinEvents, failed to fetch events from Dexcom Share (insulin import will keep retrying in the background), error = %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .error, error.localizedDescription)
            } else {
                trace("    in downloadAndProcessInsulinEvents, events fetch failed again (%{public}@ times), error = %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, eventsFetchFailedCount.description, error.localizedDescription)
            }
        }
    }

    /// Stores insulin events downloaded from Dexcom Share as insulin treatments, deduping against existing treatments.
    /// Must be called on the main thread.
    private func processInsulinEvents(_ insulinEvents: [(timeStamp: Date, value: Double)]) {
        var didAddTreatment = false

        for insulinEvent in insulinEvents {
            // sanity check on the value
            guard insulinEvent.value > 0, insulinEvent.value < 200 else { continue }

            // dedupe : skip if a non-deleted insulin treatment with (almost) the same timestamp and amount already exists
            let existingTreatments = treatmentEntryAccessor.getTreatments(fromDate: insulinEvent.timeStamp.addingTimeInterval(-ConstantsHealthKit.carbsImportDedupeWindowInSeconds), toDate: insulinEvent.timeStamp.addingTimeInterval(ConstantsHealthKit.carbsImportDedupeWindowInSeconds), on: coreDataManager.mainManagedObjectContext)
            if existingTreatments.contains(where: { $0.treatmentType == .Insulin && !$0.treatmentdeleted && abs($0.value - insulinEvent.value) < 0.01 }) { continue }

            _ = TreatmentEntry(date: insulinEvent.timeStamp, value: insulinEvent.value, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Dexcom Share", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)

            didAddTreatment = true

            trace("    in processInsulinEvents, imported insulin treatment from Dexcom Share, timestamp = %{public}@, units = %{public}@", log: log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .info, insulinEvent.timeStamp.description, insulinEvent.value.description)
        }

        if didAddTreatment {
            coreDataManager.saveChanges()

            // trigger an update of the chart and the treatments list - the HealthKitManager also observes this counter and will write the new insulin treatments to Apple Health
            UserDefaults.standard.nightscoutTreatmentsUpdateCounter = UserDefaults.standard.nightscoutTreatmentsUpdateCounter + 1
        }
    }

    /// Downloads the latest events from Dexcom Share and returns the insulin events found as (timestamp, units) tuples.
    ///
    /// The events endpoint (Publisher/ReadEvents) is part of Dexcom's newer Share API generation and expects a 'signedRequest'
    /// parameter : three base64url encoded segments (header.payload.signature), similar to a JWT. The signature is normally
    /// computed with a device key that is provisioned to the official Dexcom apps. That key is not available to third party
    /// apps, so the signature built here is a best-effort HMAC based on the session - if Dexcom rejects it, the error is
    /// handled gracefully by the caller and the insulin import simply stays inactive.
    /// - Parameters:
    ///     - sessionId: the active Dexcom Share session id
    /// - Returns: array of (timestamp, units) tuples for insulin events
    /// - Throws: DexcomShareFollowError or URL/network errors
    private func downloadLatestEvents(sessionId: String) async throws -> [(timeStamp: Date, value: Double)] {
        let region = UserDefaults.standard.dexcomShareRegion

        guard let componentsInitial = URLComponents(url: region.baseURL.appendingPathComponent(ConstantsDexcomShare.dexcomShareFollowReadEventsPath), resolvingAgainstBaseURL: false) else { throw DexcomShareFollowError.urlError }
        var components = componentsInitial

        components.queryItems = [
            .init(name: "sessionId", value: sessionId),
            .init(name: "signedRequest", value: buildSignedEventsRequest(sessionId: sessionId, region: region))
        ]

        guard let url = components.url else { throw DexcomShareFollowError.urlError }
        var request = URLRequest(url: url)

        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Dexcom Share/3.0.2.11 CFNetwork/1390 Darwin/22.0.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw DexcomShareFollowError.sessionExpired
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw DexcomShareFollowError.eventsFetchFailed
        }

        return parseInsulinEvents(fromEventsResponse: data)
    }

    /// Builds the signed request expected by the Dexcom Share events endpoint : header.payload.signature, all base64url encoded.
    private func buildSignedEventsRequest(sessionId: String, region: DexcomShareRegion) -> String {
        let iso8601DateFormatter = ISO8601DateFormatter()
        iso8601DateFormatter.formatOptions = [.withInternetDateTime]

        // request events of the last 24 hours
        let lastSyncTimestamp = iso8601DateFormatter.string(from: Date(timeIntervalSinceNow: -ConstantsDexcomShare.dexcomShareEventsFetchWindowInHours * 3600.0))

        let header: [String: Any] = [
            "AccId": dexcomShareAccountId ?? "",
            "AppId": region.applicationID,
            "IsZip": 0,
            "Timestamp": iso8601DateFormatter.string(from: Date())
        ]

        let payload: [String: Any] = [
            "SessionId": sessionId,
            "LastSyncTimestamps": ["Event": lastSyncTimestamp]
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "" }

        let headerAndPayload = base64UrlEncode(headerData) + "." + base64UrlEncode(payloadData)

        // best-effort signature : HMAC-SHA256 keyed with the session id, truncated to 16 bytes (the length observed in requests made by the official apps)
        let key = SymmetricKey(data: Data(sessionId.utf8))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(headerAndPayload.utf8), using: key).prefix(16))

        return headerAndPayload + "." + base64UrlEncode(signature)
    }

    /// base64url encoding (base64 with '+' -> '-', '/' -> '_' and no padding), as used in the Dexcom signed request
    private func base64UrlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Parses the events response and returns the insulin events found as (timestamp, units) tuples.
    ///
    /// The exact response schema of the events endpoint is not publicly documented, so this parser is deliberately tolerant :
    /// it unwraps an optional base64/gzip envelope, then recursively scans the JSON for dictionaries that look like insulin
    /// events (a type field containing 'insulin', a numeric value and a parseable timestamp).
    private func parseInsulinEvents(fromEventsResponse data: Data) -> [(timeStamp: Date, value: Double)] {
        var jsonData = data

        // the response can be a JSON envelope with a base64 encoded (and possibly gzipped) payload
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for payloadKey in ["Payload", "Body", "Data"] {
                if let payloadString = envelope[payloadKey] as? String, let payloadData = Data(base64Encoded: payloadString) {
                    jsonData = gunzipIfNeeded(payloadData)
                    break
                }
            }
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) else { return [] }

        var insulinEvents: [(timeStamp: Date, value: Double)] = []
        scanForInsulinEvents(in: jsonObject, appendingTo: &insulinEvents)

        // sort by newest first
        insulinEvents.sort { $0.timeStamp > $1.timeStamp }

        return insulinEvents
    }

    /// Recursively scans a JSON object for dictionaries that look like insulin events and appends them to the array.
    private func scanForInsulinEvents(in jsonObject: Any, appendingTo insulinEvents: inout [(timeStamp: Date, value: Double)]) {
        if let array = jsonObject as? [Any] {
            for element in array {
                scanForInsulinEvents(in: element, appendingTo: &insulinEvents)
            }
        } else if let dictionary = jsonObject as? [String: Any] {
            // does this dictionary look like an insulin event?
            var isInsulinEvent = false
            for typeKey in ["EventType", "Type", "EventName", "SubType", "Name"] {
                if let typeValue = dictionary[typeKey] as? String, typeValue.lowercased().contains("insulin") {
                    isInsulinEvent = true
                    break
                }
            }

            if isInsulinEvent, let value = parseEventValue(in: dictionary), let timeStamp = parseEventTimestamp(in: dictionary) {
                insulinEvents.append((timeStamp: timeStamp, value: value))
            } else {
                // not an insulin event (or missing fields) - keep scanning nested structures
                for nestedValue in dictionary.values {
                    scanForInsulinEvents(in: nestedValue, appendingTo: &insulinEvents)
                }
            }
        }
    }

    /// Finds the insulin amount in an event dictionary.
    private func parseEventValue(in dictionary: [String: Any]) -> Double? {
        for valueKey in ["Value", "InsulinValue", "Amount", "Units", "Dose"] {
            if let doubleValue = dictionary[valueKey] as? Double, doubleValue > 0 {
                return doubleValue
            }
            if let intValue = dictionary[valueKey] as? Int, intValue > 0 {
                return Double(intValue)
            }
            if let stringValue = dictionary[valueKey] as? String, let doubleValue = Double(stringValue), doubleValue > 0 {
                return doubleValue
            }
        }
        return nil
    }

    /// Finds and parses the timestamp in an event dictionary. Accepts Dexcom "/Date(...)/" strings, ISO8601 strings and epoch milliseconds.
    private func parseEventTimestamp(in dictionary: [String: Any]) -> Date? {
        for timeKey in ["ST", "DT", "WT", "SystemTime", "DisplayTime", "EventTime", "Timestamp", "RecordedTimestamp", "EventTimestamp"] {
            guard let timeValue = dictionary[timeKey] else { continue }

            if let timeString = timeValue as? String {
                // dexcom "/Date(...)/" format
                if let date = parseDexcomDate(dexcomDateString: timeString) {
                    return date
                }
                // ISO8601, with or without fractional seconds
                let iso8601DateFormatter = ISO8601DateFormatter()
                iso8601DateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso8601DateFormatter.date(from: timeString) {
                    return date
                }
                iso8601DateFormatter.formatOptions = [.withInternetDateTime]
                if let date = iso8601DateFormatter.date(from: timeString) {
                    return date
                }
            } else if let milliseconds = timeValue as? Double, milliseconds > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
        }
        return nil
    }

    /// If the data starts with the gzip magic bytes, strips the gzip header/trailer and inflates the raw deflate stream. Returns the data unchanged otherwise (or if decompression fails).
    private func gunzipIfNeeded(_ data: Data) -> Data {
        // gzip magic bytes 0x1f 0x8b, followed by compression method 0x08 (deflate)
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b, data[data.startIndex + 2] == 0x08 else { return data }

        let flags = data[data.startIndex + 3]
        var headerLength = 10

        // FEXTRA
        if flags & 0x04 != 0 {
            guard data.count > headerLength + 2 else { return data }
            let extraLength = Int(data[data.startIndex + headerLength]) | (Int(data[data.startIndex + headerLength + 1]) << 8)
            headerLength += 2 + extraLength
        }
        // FNAME - null terminated
        if flags & 0x08 != 0 {
            while headerLength < data.count, data[data.startIndex + headerLength] != 0 { headerLength += 1 }
            headerLength += 1
        }
        // FCOMMENT - null terminated
        if flags & 0x10 != 0 {
            while headerLength < data.count, data[data.startIndex + headerLength] != 0 { headerLength += 1 }
            headerLength += 1
        }
        // FHCRC
        if flags & 0x02 != 0 {
            headerLength += 2
        }

        guard data.count > headerLength + 8 else { return data }

        // strip gzip header and 8-byte trailer (crc32 + size), leaving the raw deflate stream that NSData can decompress using the zlib algorithm
        let deflateData = data.subdata(in: (data.startIndex + headerLength)..<(data.endIndex - 8))

        if let inflatedData = try? (deflateData as NSData).decompressed(using: .zlib) as Data {
            return inflatedData
        }

        return data
    }

    /// Disables suspension prevention by removing background/foreground closures and suspending timers
    private func disableSuspensionPrevention() {
        // stop the timer for now, might be already suspended but doesn't harm
        if let playSoundTimer = playSoundTimer {
            playSoundTimer.suspend()
        }
        
        // no need anymore to resume the player when coming in foreground
        ApplicationManager.shared.removeClosureToRunWhenAppDidEnterBackground(key: self.applicationManagerKeyResumePlaySoundTimer)
        
        // no need anymore to suspend the soundplayer when entering foreground, because it's not even resumed
        ApplicationManager.shared.removeClosureToRunWhenAppWillEnterForeground(key: self.applicationManagerKeySuspendPlaySoundTimer)
    }
    
    /// Enables suspension prevention by launching a timer to play sound in the background if required
    private func enableSuspensionPrevention() {
        // if keep-alive is disabled or if using a heartbeat, then just return and do nothing
        if !UserDefaults.standard.followerBackgroundKeepAliveType.shouldKeepAlive {
            trace("not enabling suspension prevention as keep-alive type is: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, UserDefaults.standard.followerBackgroundKeepAliveType.description)
            
            return
        }
        
        let interval = UserDefaults.standard.followerBackgroundKeepAliveType == .normal ? ConstantsSuspensionPrevention.intervalNormal : ConstantsSuspensionPrevention.intervalAggressive
        
        // create playSoundTimer depending on the keep-alive type selected
        self.playSoundTimer = RepeatingTimer(timeInterval: TimeInterval(Double(interval)), eventHandler: { [weak self] in
            guard let self = self else { return }
            // play the sound
            trace("in eventhandler checking if audioplayer exists", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .info)
            if let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying {
                trace("playing audio every %{public}@ seconds. %{public}@ keep-alive: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .info, interval.description, UserDefaults.standard.followerDataSourceType.description, UserDefaults.standard.followerBackgroundKeepAliveType.description)
                audioPlayer.play()
            }
        })
        
        // schedulePlaySoundTimer needs to be created when app goes to background
        ApplicationManager.shared.addClosureToRunWhenAppDidEnterBackground(key: self.applicationManagerKeyResumePlaySoundTimer, closure: { [weak self] in
            guard let self = self else { return }
            if UserDefaults.standard.followerBackgroundKeepAliveType.shouldKeepAlive {
                if let playSoundTimer = self.playSoundTimer {
                    playSoundTimer.resume()
                }
                if let audioPlayer = self.audioPlayer, !audioPlayer.isPlaying {
                    audioPlayer.play()
                }
            }
        })
        
        // schedulePlaySoundTimer needs to be invalidated when app goes to foreground
        ApplicationManager.shared.addClosureToRunWhenAppWillEnterForeground(key: self.applicationManagerKeySuspendPlaySoundTimer, closure: { [weak self] in
            guard let self = self else { return }
            if let playSoundTimer = self.playSoundTimer {
                playSoundTimer.suspend()
            }
        })
    }
    
    /// verifies UserDefaults and either starts or stops follower mode, including enabling/disabling suspension prevention and triggering the first download if applicable.
    private func verifyUserDefaultsAndStartOrStopFollowMode() {
        if !UserDefaults.standard.isMaster && UserDefaults.standard.followerDataSourceType == .dexcomShare && UserDefaults.standard.dexcomShareAccountName != nil && UserDefaults.standard.dexcomSharePassword != nil {
            // this will enable the suspension prevention sound playing if background keep-alive is needed
            // (i.e. not disabled and not using a heartbeat)
            if UserDefaults.standard.followerBackgroundKeepAliveType.shouldKeepAlive {
                self.enableSuspensionPrevention()
            } else {
                self.disableSuspensionPrevention()
            }
            
            // do initial download, this will also schedule future downloads
            self.download()
            
        } else {
            // disable the suspension prevention
            self.disableSuspensionPrevention()
            
            // invalidate the downloadtimer
            if let invalidateDownLoadTimerClosure = invalidateDownLoadTimerClosure {
                invalidateDownLoadTimerClosure()
            }
            // Clear session and notify delegate with empty data
            self.dexcomShareSessionId = nil
            if let followerDelegate = self.followerDelegate {
                var emptyArray: [FollowerBgReading] = []
                followerDelegate.followerInfoReceived(followGlucoseDataArray: &emptyArray)
            }
        }
    }
    
    /// Parses a Dexcom date string (e.g. "/Date(1426780716000-0700)/") into a Date object.
    /// - Parameters
    ///     - dexcomDateString: The Dexcom date string.
    /// - Returns: Date if parsing succeeds, nil otherwise.
    private func parseDexcomDate(dexcomDateString: String) -> Date? {
        // "/Date(1426780716000-0700)/" or "/Date(1426784306000)/"
        // extract epoch millis before the optional offset
        let digits = dexcomDateString.filter { "-0123456789".contains($0) }
        // find leading integer (ms)
        if let range = digits.range(of: "^-?\\d+", options: .regularExpression) {
            let millisecondsString = String(digits[range])
            if let milliseconds = Double(millisecondsString) {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
        }
        
        return nil
    }
    
    // MARK: - overriden function
    
    /// Observes UserDefaults changes and triggers state reset if relevant keys change.
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                switch keyPathEnum {
                case UserDefaults.Key.importInsulinFromDexcomShare:
                    // if the user just enabled the insulin import, reset the throttle and trigger a download cycle so the import starts immediately
                    if UserDefaults.standard.importInsulinFromDexcomShare {
                        self.timeStampLastEventsFetchAttempt = nil
                        self.eventsFetchFailedCount = 0
                        self.download()
                    }

                case UserDefaults.Key.isMaster, UserDefaults.Key.followerDataSourceType, UserDefaults.Key.dexcomShareAccountName, UserDefaults.Key.dexcomSharePassword:
                    trace("UserDefaults key changed: %{public}@", log: self.log, category: ConstantsLog.categoryDexcomShareFollowManager, type: .debug, keyPathEnum.rawValue)
                    // change by user, should not be done within 200 ms
                    if self.keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200) {
                        // reset all login information so that we provoke a new intent
                        self.dexcomShareSessionId = nil
                        UserDefaults.standard.dexcomShareRegion = .none
                        UserDefaults.standard.dexcomShareLoginFailedTimestamp = nil
                        self.verifyUserDefaultsAndStartOrStopFollowMode()
                    }
                default:
                    break
                }
            }
        }
    }
}

// MARK: - DexcomShareFollowError

/// error throwing types for the follower
private enum DexcomShareFollowError: Error {
    case authFailed
    case loginFailed
    case emptySessionID
    case noSessionID
    case invalidCredentials
    case urlError
    case sessionExpired
    case noRegion
    case eventsFetchFailed
}

// MARK: CustomStringConvertible

/// make a custom description property to correctly log the error types
extension DexcomShareFollowError: CustomStringConvertible {
    var description: String {
        switch self {
        case .authFailed:
            return "Authorization Failed"
        case .loginFailed:
            return "Login Failed"
        case .emptySessionID:
            return "Empty Session ID"
        case .noSessionID:
            return "No Session ID"
        case .invalidCredentials:
            return "Invalid credentials (check 'Settings' > 'Connection Settings')"
        case .urlError:
            return "URL Error"
        case .sessionExpired:
            return "Session Expired"
        case .noRegion:
            return "No region has been set/detected"
        case .eventsFetchFailed:
            return "Events (insulin) fetch failed"
        }
    }
}
