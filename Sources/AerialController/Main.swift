import AppKit
import SwiftUI

@MainActor
final class ControllerAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "航拍控制器")
            button.toolTip = "航拍控制器"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 360, height: 650)
        popover.contentViewController = NSHostingController(rootView: ControllerPanel(model: model, onDesktopPlaybackRequested: { [weak self] in
            self?.popover.performClose(nil)
        }))
        // AppModel restores saved rotation only after its environment checks.
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            keepPopoverStationary()
        }
    }

    func popoverWillShow(_ notification: Notification) { keepPopoverStationary() }
    func popoverDidShow(_ notification: Notification) { keepPopoverStationary() }

    private func keepPopoverStationary() {
        guard let window = popover.contentViewController?.view.window else { return }
        // The popover's transient close behavior is independent of its window's
        // collection behavior. Only this content window stays out of Expose;
        // never change the system-owned status-item anchor window.
        var behavior = window.collectionBehavior
        behavior.subtract([.managed, .transient, .participatesInCycle])
        behavior.formUnion([.stationary, .ignoresCycle])
        window.collectionBehavior = behavior
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isSwitching ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) { model.stopForTermination() }
}

@main
struct AerialControllerMain {
    nonisolated static func main() {
        // Enter the AppKit event loop synchronously on the process main thread.
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = ControllerAppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { application.run() }
        }
    }
}
