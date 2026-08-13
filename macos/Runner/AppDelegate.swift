import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate, NetServiceDelegate, NetServiceBrowserDelegate {

    private let serviceType = "_oneshare._tcp."

    private var controlChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    private var publishedService: NetService?
    private var serviceBrowser: NetServiceBrowser?

    private var discoveredServices: [String: NetService] = [:]

    func registerFlutterChannels(
        messenger: FlutterBinaryMessenger
    ) {
        let control = FlutterMethodChannel(
            name: "com.example.oneshare/nsd_control",
            binaryMessenger: messenger
        )

        let events = FlutterEventChannel(
            name: "com.example.oneshare/nsd_events",
            binaryMessenger: messenger
        )

        controlChannel = control

        events.setStreamHandler(self)

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

        print(
            "OneShare-NSD macOS: starting discovery \(serviceType)"
        )

        browser.searchForServices(
            ofType: serviceType,
            inDomain: ""
        )
    }

    private func stopDiscovery() {
        serviceBrowser?.stop()
        serviceBrowser = nil

        for service in discoveredServices.values {
            service.stop()
        }

        discoveredServices.removeAll()
    }

    // MARK: NetServiceDelegate

    func netServiceDidPublish(_ sender: NetService) {
        print(
            "OneShare-NSD macOS: published \(sender.name):\(sender.port)"
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

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        print(
            "OneShare-NSD macOS: resolve failed " +
            "\(sender.name) \(errorDict)"
        )

        discoveredServices.removeValue(forKey: sender.name)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else {
            return
        }

        for addressData in addresses {
            guard addressData.count >= MemoryLayout<sockaddr_in>.size else {
                continue
            }

            let host: String? = addressData.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return nil
                }

                let sockaddrPointer =
                    baseAddress.assumingMemoryBound(to: sockaddr.self)

                var hostBuffer = [CChar](
                    repeating: 0,
                    count: Int(NI_MAXHOST)
                )

                let result = getnameinfo(
                    sockaddrPointer,
                    socklen_t(addressData.count),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                guard result == 0 else {
                    return nil
                }

                return String(cString: hostBuffer)
            }

            if let host = host {
                print(
                    "OneShare-NSD macOS: resolved " +
                    "\(sender.name) \(host):\(sender.port)"
                )

                sendResolved(
                    serviceName: sender.name,
                    host: host,
                    port: sender.port
                )

                break
            }
        }
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowserWillSearch(
        _ browser: NetServiceBrowser
    ) {
        print(
            "OneShare-NSD macOS: browser started"
        )
    }

    func netServiceBrowserDidStopSearch(
        _ browser: NetServiceBrowser
    ) {
        print(
            "OneShare-NSD macOS: browser stopped"
        )
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        print(
            "OneShare-NSD macOS: browser failed \(errorDict)"
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

        service.delegate = self
        discoveredServices[service.name] = service
        service.resolve(withTimeout: 3.0)
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