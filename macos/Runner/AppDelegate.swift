import Cocoa
import FlutterMacOS
import CoreWLAN

@main
class AppDelegate: FlutterAppDelegate, NetServiceDelegate, NetServiceBrowserDelegate, CWEventDelegate {

    private let serviceType = "_oneshare._tcp."

    private var controlChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    private var wifiControlChannel: FlutterMethodChannel?
    private var wifiEventChannel: FlutterEventChannel?
    private var wifiEventSink: FlutterEventSink?
    private var currentWifiStatus: Bool = true

    private var publishedService: NetService?
    private var serviceBrowser: NetServiceBrowser?

    private var discoveredServices: [String: NetService] = [:]

    func registerFlutterChannels(
        messenger: FlutterBinaryMessenger
    ) {
        let control = FlutterMethodChannel(
            name: "com.oneshare.app/nsd_control",
            binaryMessenger: messenger
        )

        let events = FlutterEventChannel(
            name: "com.oneshare.app/nsd_events",
            binaryMessenger: messenger
        )

        controlChannel = control
        events.setStreamHandler(self)

        // Native Wi-Fi status channels
        let wifiControl = FlutterMethodChannel(
            name: "com.oneshare.app/wifi_control",
            binaryMessenger: messenger
        )
        let wifiEvents = FlutterEventChannel(
            name: "com.oneshare.app/wifi_events",
            binaryMessenger: messenger
        )

        wifiControlChannel = wifiControl
        wifiEventChannel = wifiEvents

        wifiControl.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "UNAVAILABLE", message: "AppDelegate unavailable", details: nil))
                return
            }
            if call.method == "getWifiStatus" {
                let status = self.queryCoreWLANPowerState()
                self.currentWifiStatus = status
                print("OneShare-WiFi macOS: getWifiStatus called -> \(status)")
                result(status)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }

        wifiEvents.setStreamHandler(WifiStreamHandler(appDelegate: self))

        setupCoreWLANMonitoring()

        print("OneShare-NSD macOS: Flutter channels registered")

        control.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(
                    FlutterError(
                        code: "APP_DEALLOCATED",
                        message: "AppDelegate unavailable",
                        details: nil
                    )
                )
                return
            }

            switch call.method {
            case "startAdvertising":
                guard
                    let arguments = call.arguments as? [String: Any],
                    let deviceName = arguments["deviceName"] as? String,
                    let port = arguments["port"] as? Int
                else {
                    result(
                        FlutterError(
                            code: "INVALID_ARGUMENTS",
                            message: "Missing deviceName or port",
                            details: nil
                        )
                    )
                    return
                }

                print(
                    "OneShare-NSD macOS: startAdvertising " +
                    "\(deviceName):\(port)"
                )

                self.startAdvertising(
                    deviceName: deviceName,
                    port: port
                )

                result(nil)

            case "stopAdvertising":
                print("OneShare-NSD macOS: stopAdvertising")
                self.stopAdvertising()
                result(nil)

            case "startDiscovery":
                print("OneShare-NSD macOS: startDiscovery")
                self.startDiscovery()
                result(nil)

            case "stopDiscovery":
                print("OneShare-NSD macOS: stopDiscovery")
                self.stopDiscovery()
                result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func queryCoreWLANPowerState() -> Bool {
        if let iface = CWWiFiClient.shared().interface() {
            return iface.powerOn()
        }
        return true
    }

    private func setupCoreWLANMonitoring() {
        currentWifiStatus = queryCoreWLANPowerState()
        CWWiFiClient.shared().delegate = self
        do {
            try CWWiFiClient.shared().startMonitoringEvent(with: .powerDidChange)
            print("OneShare-WiFi macOS: CoreWLAN powerDidChange monitoring started. Initial state: \(currentWifiStatus)")
        } catch {
            print("OneShare-WiFi macOS: Failed to start CoreWLAN monitoring: \(error)")
        }

        // Secondary notification listener for Darwin power notifications
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("com.apple.corewlan.powerDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let isPowerOn = self.queryCoreWLANPowerState()
            print("OneShare-WiFi macOS: Notification powerDidChange received -> \(isPowerOn)")
            self.currentWifiStatus = isPowerOn
            self.wifiEventSink?(isPowerOn)
        }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        let isPowerOn = CWWiFiClient.shared().interface(withName: interfaceName)?.powerOn() ?? queryCoreWLANPowerState()
        print("OneShare-WiFi macOS: CWEventDelegate powerStateDidChange for \(interfaceName) -> \(isPowerOn)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentWifiStatus = isPowerOn
            self.wifiEventSink?(isPowerOn)
        }
    }

    override func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        return true
    }

    override func applicationSupportsSecureRestorableState(
        _ app: NSApplication
    ) -> Bool {
        return true
    }

    private func startAdvertising(
        deviceName: String,
        port: Int
    ) {
        stopAdvertising()

        let service = NetService(
            domain: "",
            type: serviceType,
            name: deviceName,
            port: Int32(port)
        )

        service.delegate = self
        publishedService = service

        print(
            "OneShare-NSD macOS: publishing \(deviceName) on port \(port)"
        )

        service.publish(options: [])
    }

    private func stopAdvertising() {
        publishedService?.stop()
        publishedService = nil
    }

    private func startDiscovery() {
        stopDiscovery()

        let browser = NetServiceBrowser()
        browser.delegate = self
        serviceBrowser = browser

        discoveredServices.removeAll()

        print(
            "OneShare-NSD macOS: browsing for \(serviceType)"
        )

        browser.searchForServices(
            ofType: serviceType,
            inDomain: "local."
        )
    }

    private func stopDiscovery() {
        serviceBrowser?.stop()
        serviceBrowser = nil

        for (_, service) in discoveredServices {
            service.stop()
        }

        discoveredServices.removeAll()
    }

    func netServiceDidPublish(_ sender: NetService) {
        print(
            "OneShare-NSD macOS: successfully published \(sender.name)"
        )
    }

    func netService(
        _ sender: NetService,
        didNotPublish errorDict: [String: NSNumber]
    ) {
        print(
            "OneShare-NSD macOS: publish failed \(errorDict)"
        )
    }

    func netServiceDidStop(_ sender: NetService) {
        print(
            "OneShare-NSD macOS: service stopped \(sender.name)"
        )
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        print(
            "OneShare-NSD macOS: found \(service.name)"
        )

        discoveredServices[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else {
            print(
                "OneShare-NSD macOS: resolved without hostName"
            )
            return
        }

        let port = sender.port

        print(
            "OneShare-NSD macOS: resolved \(sender.name) -> " +
            "\(hostName):\(port)"
        )

        sendResolved(
            serviceName: sender.name,
            host: hostName,
            port: port
        )
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        print(
            "OneShare-NSD macOS: resolve failed for " +
            "\(sender.name): \(errorDict)"
        )
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        print(
            "OneShare-NSD macOS: lost \(service.name)"
        )

        discoveredServices.removeValue(forKey: service.name)

        eventSink?([
            "event": "lost",
            "serviceName": service.name
        ])
    }

    private func sendResolved(
        serviceName: String,
        host: String,
        port: Int
    ) {
        eventSink?([
            "event": "resolved",
            "serviceName": serviceName,
            "host": host,
            "port": port
        ])
    }

    fileprivate func setWifiSink(_ sink: FlutterEventSink?) {
        self.wifiEventSink = sink
        let status = queryCoreWLANPowerState()
        self.currentWifiStatus = status
        sink?(status)
    }
}

private class WifiStreamHandler: NSObject, FlutterStreamHandler {
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        appDelegate?.setWifiSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        appDelegate?.setWifiSink(nil)
        return nil
    }
}

extension AppDelegate: FlutterStreamHandler {

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        self.eventSink = events
        print("OneShare-NSD macOS: event stream connected")
        return nil
    }

    func onCancel(
        withArguments arguments: Any?
    ) -> FlutterError? {
        self.eventSink = nil
        print("OneShare-NSD macOS: event stream disconnected")
        return nil
    }
}