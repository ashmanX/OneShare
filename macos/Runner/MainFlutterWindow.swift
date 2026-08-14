import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame

        self.contentViewController = flutterViewController
        self.minSize = NSSize(width: 480, height: 640)
        self.maxSize = NSSize(width: 800, height: 900)
        self.setFrame(NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y, width: 560, height: 720), display: true)

        // Disable full-screen mode on macOS
        self.collectionBehavior.remove(.fullScreenPrimary)
        self.collectionBehavior.insert(.fullScreenNone)

        RegisterGeneratedPlugins(registry: flutterViewController)

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.registerFlutterChannels(
                messenger: flutterViewController.engine.binaryMessenger
            )
        }

        super.awakeFromNib()
    }
}