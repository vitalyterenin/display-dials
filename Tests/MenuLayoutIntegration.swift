import AppKit

@MainActor
final class LayoutProbe: NSObject {
    let menu: NSMenu
    var failures: [String] = []
    var inspected = false

    init(menu: NSMenu) { self.menu = menu }

    @objc func inspect() {
        inspected = true
        let frame = menu.accessibilityFrame()
        let expected = menu.size
        if frame.height + 1 < expected.height {
            failures.append("Menu clipped: rendered \(frame.height), required \(expected.height).")
        }
        for item in menu.items where !item.isSeparatorItem {
            let row = item.accessibilityFrame()
            if row.isEmpty || !frame.insetBy(dx: -1, dy: -1).contains(row) {
                failures.append("Row is not fully visible: \(item.title), \(row), menu \(frame).")
            }
        }
        print("Visible menu: \(menu.numberOfItems) items, frame \(frame), required \(expected).")
        menu.cancelTracking()
    }
}

@main
struct MenuLayoutIntegration {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let anchor = status.button else { exit(1) }
        anchor.title = "T"
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        app.activate(ignoringOtherApps: true)
        let panel = NSViewController()
        panel.view = NSView(frame: NSRect(x: 0, y: 0, width: 288, height: 116))
        let more = NSButton(frame: NSRect(x: 248, y: 68, width: 24, height: 24))
        panel.view.addSubview(more)
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = panel
        popover.contentSize = panel.view.frame.size
        popover.behavior = .transient
        var failures: [String] = []
        for count in [8, 16, 24] {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            let menu = NSMenu()
            menu.autoenablesItems = false
            for index in 0..<count {
                menu.addItem(withTitle: "Option \(index + 1)", action: nil, keyEquivalent: "")
            }
            let probe = LayoutProbe(menu: menu)
            let timer = Timer(timeInterval: 0.3, target: probe, selector: #selector(LayoutProbe.inspect),
                              userInfo: nil, repeats: false)
            RunLoop.main.add(timer, forMode: .common)
            OptionsMenuPresentation.popUp(menu, from: more)
            timer.invalidate()
            if !probe.inspected { failures.append("Menu did not stay open for inspection.") }
            failures += probe.failures
        }
        popover.close()
        NSStatusBar.system.removeStatusItem(status)
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("Actual popover menu growth checks passed without scrolling.")
    }
}
