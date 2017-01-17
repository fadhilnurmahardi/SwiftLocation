//
//  LocationManager.swift
//  SwiftLocation
//
//  Created by Daniele Margutti on 08/01/2017.
//  Copyright © 2017 Daniele Margutti. All rights reserved.
//

import Foundation
import MapKit
import CoreLocation

public let Location = LocationTracker.shared

public final class LocationTracker: NSObject, CLLocationManagerDelegate {
	
	/// This is a reference to LocationManager's singleton where the main queue for Requests.
	static let shared : LocationTracker = {
		let instance = LocationTracker()
		return instance
	}()
	
	/// Initialize func
	private override init() {
		self.locationManager = CLLocationManager()
		super.init()
		self.locationManager.delegate = self
	}
	
	/// Internal location manager reference
	private var locationManager: CLLocationManager
	
	/// Queued requests regarding location services
	private var locationObservers: [LocationRequest] = []
	
	/// Queued requests regarding reverse geocoding services
	private var reverseGeocoderObservers: [GeocoderRequest] = []
	
	/// Queued requests regarding heading services
	private var headingObservers: [HeadingRequest] = []
	
	/// This represent the status of the authorizations before a change
	private var lastStatus: CLAuthorizationStatus = CLAuthorizationStatus.notDetermined
	
	/// `true` to listen for application's state change from background to foreground and viceversa
	private var _listenForAppState: Bool = false
	private var listenForAppState: Bool {
		set {
			func disableNotifications() {
				 NotificationCenter.default.removeObserver(self)
			}
			func enableNotifications() {
				let center = NotificationCenter.default
				center.addObserver(self,
				                   selector:  #selector(applicationDidEnterBackground),
				                   name: NSNotification.Name.UIApplicationDidEnterBackground,
				                   object: nil)
				center.addObserver(self,
				                   selector:  #selector(applicationDidBecomeActive),
				                   name: NSNotification.Name.UIApplicationDidBecomeActive,
				                   object: nil)
			}
			guard _listenForAppState != newValue else {
				return
			}
			_listenForAppState = newValue
			disableNotifications()
			if newValue == true {
				enableNotifications()
			}
		}
		get {
			return _listenForAppState
		}
	}
	
	/// This represent the last locations received (best accurated location and last received location)
	private(set) var lastLocation = LastLocation()
	public struct LastLocation {
		/// This is the best accurated measured location (may be old, check the `timestamp`)
		public var bestAccurated: CLLocation?
		/// This represent the last measured location by timestamp (may be innacurate, check `accuracy`)
		public var last: CLLocation?
		
		/// Store last value
		///
		/// - Parameter location: location to set
		mutating internal func set(location: CLLocation) {
			if bestAccurated == nil {
				self.bestAccurated = location
			} else if location.horizontalAccuracy > self.bestAccurated!.horizontalAccuracy {
				self.bestAccurated = location
			}
			if last == nil {
				self.last = location
			} else if location.timestamp > self.last!.timestamp {
				self.last = location
			}
		}
	}
	
	
	/// Active CoreLocation settings based upon running requests
	private var _locationSettings: Settings?
	private(set) var locationSettings: Settings? {
		set {
			
			func stopLocationServices() {
				locationManager.stopUpdatingLocation()
				locationManager.stopMonitoringSignificantLocationChanges()
				locationManager.disallowDeferredLocationUpdates()
			}
			
			guard let settings = newValue else {
				stopLocationServices()
				_locationSettings = newValue
				return
			}
			
			if _locationSettings == newValue {
				return // ignore equal settings, avoid multiple sets
			}
			
			print("New settings: \(newValue)")
			_locationSettings = newValue
			// Set attributes for CLLocationManager instance
			locationManager.activityType = settings.activity // activity type (used to better preserve battery based upon activity)
			locationManager.desiredAccuracy = settings.accuracy.meters // accuracy (used to preserve battery based upon update frequency)
			
			switch settings.frequency {
			case .significant:
				guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
					stopLocationServices()
					return
				}
				// If best frequency is significant location update (and hardware supports it) then start only significant location update
				locationManager.stopUpdatingLocation()
				locationManager.startMonitoringSignificantLocationChanges()
				locationManager.disallowDeferredLocationUpdates()
			case .whenTravelled(let meters, let timeout):
				locationManager.stopMonitoringSignificantLocationChanges()
				locationManager.startUpdatingLocation()
				locationManager.allowDeferredLocationUpdates(untilTraveled: meters, timeout: timeout)
			default:
				locationManager.stopMonitoringSignificantLocationChanges()
				locationManager.startUpdatingLocation()
				locationManager.disallowDeferredLocationUpdates()
			}
		}
		get {
			return _locationSettings
		}
	}
	
	public struct Settings: CustomStringConvertible, Equatable {
		/// Accuracy set
		var accuracy: Accuracy
		
		/// Frequency set
		var frequency: Frequency
		
		/// Activity type set
		var activity: CLActivityType
		
		/// Description of the settings
		public var description: String {
			return "Settings:\n -Accuracy: \(accuracy)\n -Frequency:\(frequency)\n -Activity:\(activity)"
		}
		
		/// Returns a Boolean value indicating whether two values are equal.
		///
		/// Equality is the inverse of inequality. For any values `a` and `b`,
		/// `a == b` implies that `a != b` is `false`.
		///
		/// - Parameters:
		///   - lhs: A value to compare.
		///   - rhs: Another value to compare.
		public static func ==(lhs: LocationTracker.Settings, rhs: LocationTracker.Settings) -> Bool {
			return (lhs.accuracy.orderValue == rhs.accuracy.orderValue && lhs.frequency == rhs.frequency && lhs.activity == rhs.activity)
		}
	}
	
	private var background: BackgroundTask = BackgroundTask()
	internal class BackgroundTask {
		var task: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid
		var timer: Timer?
		
		func stop() {
			timer?.invalidate()
			UIApplication.shared.endBackgroundTask(self.task)
		}
		
		func start(time: Double) {
			self.task = UIApplication.shared.beginBackgroundTask(expirationHandler: {
				self.start(time: 10)
			})
		}
		
		@objc private func startTrackingBg() {
			let rm = UIApplication.shared.backgroundTimeRemaining
			print("Call for location (rem=\(rm))")
			Location.locationManager.requestLocation()
			start(time: 10)
		}
		
		
		private func endBackgroundUpdateTask(taskID: UIBackgroundTaskIdentifier) {
			UIApplication.shared.endBackgroundTask(taskID)
		}
	}

	/// This value is measured in meters and allows to generate new events only if horizontal distance
	/// from previous measured point is changed by given `distanceFilter`. By default all events are generated
	/// and passed.
	/// This property is used only in conjunction with the standard location services and is not used when monitoring
	/// significant location changes.
	public var distanceFilter: CLLocationDistance = kCLDistanceFilterNone {
		didSet {
			locationManager.distanceFilter = distanceFilter
		}
	}
	
	/// When `true` this property is a good way to improve battery life.
	/// This function also scan for any running Request's `activityType` and see if location data is unlikely to change.
	/// If yes (for example when user stops for food while using a navigation app) the location manager might pause updates
	/// for a period of time.
	/// By default is set to `false`.
	public var autoPauseUpdates: Bool = false {
		didSet {
			locationManager.pausesLocationUpdatesAutomatically = autoPauseUpdates
		}
	}
	
	/// Create and enque a new location tracking request
	///
	/// - Parameters:
	///   - accuracy: accuracy of the location request (it may affect device's energy consumption)
	///   - frequency: frequency of the location retrive process (it may affect device's energy consumption)
	///   - timeout: optional timeout. If no location were found before timeout a `LocationError.timeout` error is reported.
	///   - success: success handler to call when a new location were found for this request
	///   - error: error handler to call when an error did occour while searching for request
	/// - Returns: request
	@discardableResult
	public func getLocation(accuracy: Accuracy, frequency: Frequency, timeout: TimeInterval? = nil, success: @escaping LocationRequest.OnSuccessCallback, error: @escaping LocationRequest.OnErrorCallback) -> LocationRequest {
		
		let req = LocationRequest(accuracy: accuracy, frequency: frequency, success, error)
		req.timeout = timeout
		req.resume()
		return req
	}
	
	
	/// Create and enqueue a new reverse geocoding request for an input address string
	///
	/// - Parameters:
	///   - address: address string to reverse
	///   - region: A geographical region to use as a hint when looking up the specified address.
	///				Specifying a region lets you prioritize the returned set of results to locations that are close to some
	///				specific geographical area, which is typically the user’s current location.
	///   - timeout: timeout of the operation; nil to ignore timeout, a valid seconds interval. If reverse geocoding does not succeded or
	///				 fail inside this time interval request fails with `LocationError.timeout` error and registered callbacks are called.
	///
	///   - success: success handler to call when reverse geocoding succeded
	///   - failure: failure handler to call when reverse geocoding fails
	/// - Returns: request
	@discardableResult
	public func getLocation(forString address: String, inRegion region: CLRegion? = nil, timeout: TimeInterval? = nil,
	                        success: @escaping GeocoderCallback.onSuccess, failure: @escaping GeocoderCallback.onError) -> GeocoderRequest {
		let req = GeocoderRequest(address: address, region: region, success, failure)
		req.timeout = timeout
		req.resume()
		return req
	}
	
	
	/// Create and enqueue a new reverse geocoding request for an instance of `CLLocation` object.
	///
	/// - Parameters:
	///   - location: location to reverse
	///   - timeout: timeout of the operation; nil to ignore timeout, a valid seconds interval. If reverse geocoding does not succeded or
	///				 fail inside this time interval request fails with `LocationError.timeout` error and registered callbacks are called.
	///   - success: success handler to call when reverse geocoding succeded
	///   - failure: failure handler to call when reverse geocoding fails
	/// - Returns: request
	@discardableResult
	public func getLocation(forLocation location: CLLocation, timeout: TimeInterval? = nil,
	                        success: @escaping GeocoderCallback.onSuccess, failure: @escaping GeocoderCallback.onError) -> GeocoderRequest {
		let req = GeocoderRequest(location: location, success, failure)
		req.timeout = timeout
		req.resume()
		return req
	}
	
	
	/// Create and enqueue a new reverse geocoding request for an Address Book `Dictionary` object.
	///
	/// - Parameters:
	///   - dict: address book dictionary
	///   - timeout: timeout of the operation; nil to ignore timeout, a valid seconds interval. If reverse geocoding does not succeded or
	///				 fail inside this time interval request fails with `LocationError.timeout` error and registered callbacks are called.
	///   - success: success handler to call when reverse geocoding succeded
	///   - failure: failure handler to call when reverse geocoding fails
	/// - Returns: request
	public func getLocation(forABDictionary dict: [AnyHashable: Any], timeout: TimeInterval? = nil,
	                        success: @escaping GeocoderCallback.onSuccess, failure: @escaping GeocoderCallback.onError) -> GeocoderRequest {
		let req = GeocoderRequest(abDictionary: dict, success, failure)
		req.timeout = timeout
		req.resume()
		return req
	}
	
	//MARK: Register/Unregister location requests
	
	/// Register a new request and enqueue it
	///
	/// - Parameter request: request to enqueue
	/// - Returns: `true` if added correctly to the queue, `false` otherwise.
	public func start<T: Request>(_ requests: T...) {
		var hasChanges = false
		for request in requests {
			
			// Location Requests
			if let request = request as? LocationRequest {
				let isAppInBackground = (UIApplication.shared.applicationState == .background)
				let canStart = (isAppInBackground && request.isBackgroundRequest) || (!isAppInBackground && !request.isBackgroundRequest)
				if canStart == true {
					request._state = .running
					if self.isQueued(request) == true { continue }
					self.locationObservers.append(request)
					hasChanges = true
				}
			}
			
			// Geocoder Requests
			if let request = request as? GeocoderRequest {
				request._state = .running
				if self.isQueued(request) == true { continue }
				self.reverseGeocoderObservers.append(request)
				hasChanges = true
			}
			
			// Heading requests
			if let request = request as? HeadingRequest {
				request._state = .running
				if self.isQueued(request) == true { continue }
				self.headingObservers.append(request)
				hasChanges = true
			}
			
		}
		if hasChanges {
			self.updateLocationServices()
			self.updateHeadingServices()
			requests.forEach { $0.onResume() }
		}
	}
	
	
	/// Unregister and stops a queued request
	///
	/// - Parameter request: request to remove
	/// - Returns: `true` if request was removed successfully, `false` if it's not part of the queue
	public func cancel<T: Request>(_ requests: T...) {
		var hasChanges = false
		for request in requests {
			if self.isQueued(request) == false {
				continue
			}
			
			// Location Requests
			if let request = request as? LocationRequest {
				locationObservers.remove(at: locationObservers.index(of: request)!)
				request._state = .idle
				hasChanges = true
			}
			
			// Geocoder requests
			if let request = request as? GeocoderRequest {
				locationObservers.remove(at: reverseGeocoderObservers.index(of: request)!)
				request._state = .idle
				hasChanges = true
			}
			
			// Heading requests
			if let request = request as? HeadingRequest {
				headingObservers.remove(at: headingObservers.index(of: request)!)
				request._state = .idle
				hasChanges = true
			}
		}

		if hasChanges == true {
			self.updateLocationServices()
			self.updateHeadingServices()
			requests.forEach { $0.onCancel() }
		}
	}
	
	/// Pause any passed queued reques
	///
	/// - Parameter requests: requests to pause
	public func pause<T: Request>(_ requests: T...) {
		var hasChanges = false
		for request in requests {
			if self.isQueued(request) == false { continue }
			
			if self.isQueued(request) && request.state.isRunning {
				
				// Location requests
				if let request = request as? LocationRequest {
					request._state = .paused
					hasChanges = true
				}
				
				// Geocoder requests
				if let request = request as? GeocoderRequest {
					request._state = .paused
					hasChanges = true
				}
				
				// Heading requests
				if let request = request as? HeadingRequest {
					request._state = .paused
					hasChanges = true
				}
			}
		}
		
		if hasChanges == true {
			self.updateLocationServices()
			self.updateHeadingServices()
			requests.forEach { $0.onPause() }
		}
	}
	
	/// Return `true` if target `request` is part of a queue.
	///
	/// - Parameter request: target request
	/// - Returns: `true` if request is in a queue, `false` otherwise
	internal func isQueued<T: Request>(_ request: T?) -> Bool {
		guard let request = request else { return false }
		
		// Location Request
		if let request = request as? LocationRequest {
			return locationObservers.contains(request)
		}
		
		// Geocoder Request
		if let request = request as? GeocoderRequest {
			return reverseGeocoderObservers.contains(request)
		}
		return false
	}
	
	//MARK: Internal Heading Manager Func
	
	internal func updateHeadingServices() {
		let countRunning = headingObservers.reduce(0, { return $0 + ($1.state.isRunning ? 1 : 0) } )
		guard countRunning > 0 else {
			// There is not any running request, we can stop location service to preserve battery.
			locationManager.stopUpdatingHeading()
			return
		}
		locationManager.startUpdatingHeading()
	}
	
	//MARK: Internal Location Manager Func
	
	/// Update location services based upon running Requests
	internal func updateLocationServices() {
		let hasBackgroundRequests = self.loc_hasBackgroundRequiredRequests()
		self.listenForAppState = hasBackgroundRequests

		let countRunning = locationObservers.reduce(0, { return $0 + ($1.state.isRunning ? 1 : 0) } )
		guard countRunning > 0 else {
			// There is not any running request, we can stop location service to preserve battery.
			locationManager.stopUpdatingLocation()
			locationManager.stopMonitoringSignificantLocationChanges()
			return
		}
		
		do {
			// Evaluate best accuracy,frequency and activity type based upon all queued requests
			guard let bestSettings = self.loc_bestSettings() else {
				// No need to setup CLLocationManager, stop it.
				self.locationSettings = nil
				return
			}
			
			// Request authorizations if needed
			if bestSettings.accuracy.accuracyRequireAuthorization == true {
				// Check if device supports location services.
				// If not dispatch the error to any running request and stop.
				guard CLLocationManager.locationServicesEnabled() else {
					locationObservers.forEach { $0.dispatch(error: LocationError.serviceNotAvailable) }
					return
				}
				
				// Check if we need to require user authorization to use location services
				if try locationManager.requireAuthIfNeeded() == true {
					// If requested, show the system modal and put any running request in `.waitingUserAuth` status
					// then keep wait for any authorization status change
					self.loc_setRequestState(.waitingUserAuth, forRequestsIn: [.running,.idle])
					return
				}
			}
			
			// If there is a request which needs background capabilities and we have not set it
			// dispatch proper error.
			if hasBackgroundRequests && CLLocationManager.isBackgroundUpdateEnabled == false {
				locationObservers.forEach { $0.dispatch(error: LocationError.backgroundModeNotSet) }
				return
			}
			
			// Everything is okay we can setup CLLocationManager based upon the most accuracted/most frequent
			// Request queued and running.
			
			let isAppInBackground = (UIApplication.shared.applicationState == .background && CLLocationManager.isBackgroundUpdateEnabled)
			self.locationManager.allowsBackgroundLocationUpdates = isAppInBackground
			if isAppInBackground { self.autoPauseUpdates = false }
			
			// Resume any paused request (a paused request is in `.waitingUserAuth`,`.paused` or `.failed`)
			locationObservers.forEach { $0.resume() }
			
			// Setup with best settings
			self.locationSettings = bestSettings
		} catch {
			// Something went wrong, stop all...
			self.locationSettings = nil
			// ... and dispatch error to any request
			locationObservers.forEach { $0.dispatch(error: error) }
		}
	}
	
	/// Set the request's `state` for any queued requests which is in one the following states
	///
	/// - Parameters:
	///   - newState: new state to set
	///   - states: request's allowed state to be changed
	private func loc_setRequestState(_ newState: RequestState, forRequestsIn states: Set<RequestState>) {
		locationObservers.forEach {
			if states.contains($0.state) {
				$0._state = newState
			}
		}
	}
	
	/// Return `true` if a running activity needs background capabilities, `false` otherwise
	///
	/// - Returns: boolean
	private func loc_hasBackgroundRequiredRequests() -> Bool {
		for request in self.locationObservers {
			if request.isBackgroundRequest {
				return true
			}
		}
		return false
	}
	
	/// Evaluate best settings based upon running location requests
	///
	/// - Returns: best settings
	private func loc_bestSettings() -> Settings? {
		guard locationObservers.count > 0 else {
			return nil // no settings, location manager can be disabled
		}
		
		var accuracy: Accuracy = locationObservers.first!.accuracy
		var frequency: Frequency = locationObservers.first!.frequency
		var type: CLActivityType = locationObservers.first!.activity
		
		for i in 1 ..< locationObservers.count {
			let request = locationObservers[i]
			guard request.state.isRunning else {
				continue // request is not running, can be ignored
			}
			
			if request.accuracy.orderValue < accuracy.orderValue {
				accuracy = request.accuracy
			}
			if request.frequency < frequency {
				frequency = request.frequency
			}
			if request.activity.rawValue > type.rawValue {
				type = request.activity
			}
		}
	
		return Settings(accuracy: accuracy, frequency: frequency, activity: type)
	}
	
	//MARK: Application State
	
	@objc func applicationDidEnterBackground() {
		self.updateRequestStateAccordingToAppState(true)
		self.background.start(time: 10)
		self.updateLocationServices()
	}
	
	@objc func applicationDidBecomeActive() {
		self.updateRequestStateAccordingToAppState(false)
		self.background.stop()
		self.updateLocationServices()
	}
	
	/// Pause and Resume requests based upon their type (background/foreground based activities)
	///
	/// - Parameter isBackground: `true` if app is entering in background mode, `false` otherwise
	private func updateRequestStateAccordingToAppState(_ isBackground: Bool) {
		self.locationObservers.forEach {
			if isBackground == true {
				// when app is in background all foreground based request are paused
				// while any background request is resumed.
				if $0.isBackgroundRequest == false { $0.pause() }
				else { $0.resume() }
			} else {
				// viceversa when app is in foreground all background-based activities are
				// paused and foreground requests are resumed
				if $0.isBackgroundRequest == true { $0.pause() }
				else { $0.resume() }
			}
		}
		// Then unpdate the location manager based upon current settings
		self.updateLocationServices()
	}
	
	//MARK: CLLocationManager Delegate
	
	@objc open func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
		locationObservers.forEach { $0.dispatchAuthChange(self.lastStatus, status) }
		self.lastStatus = status
		
		switch status {
		case .denied, .restricted:
			locationObservers.forEach { $0.dispatch(error: LocationError.authDidChange(status)) }
			self.updateLocationServices()
		case .authorizedAlways, .authorizedWhenInUse:
			locationObservers.forEach { $0.resume() }
			self.updateLocationServices()
		default:
			break
		}
	}
	
	@objc open func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
		locationObservers.forEach { $0.dispatch(error: error) }
	}
	
	@objc public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let location = locations.max(by: { (l1, l2) -> Bool in
			return l1.timestamp.timeIntervalSince1970 < l2.timestamp.timeIntervalSince1970}
			) else {
				return
		}
		print("\(Date())  -> \(location.horizontalAccuracy), \(location.coordinate.latitude), \(location.coordinate.longitude)")
		self.lastLocation.set(location: location)
		locationObservers.forEach { $0.dispatch(location: location) }
	}
}
