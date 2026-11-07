import AppKit

@MainActor
final class RecordingMenu: NSMenu {
    var presentedPoint: NSPoint?
    var presentedView: NSView?
    var didPresent = false

    override func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        didPresent = true
        presentedPoint = location
        presentedView = view
        return false
    }
}

@main
struct MenuPresentationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        // Exercise a popover-sized window, including an offset secondary screen.
        for origin in [NSPoint(x: 300, y: 200), NSPoint(x: -1400, y: -300)] {
            let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 288, height: 116)),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            let container = NSView(frame: NSRect(x: 10, y: 10, width: 268, height: 96))
            window.contentView!.addSubview(container)
            let button = NSButton(frame: NSRect(x: 220, y: 60, width: 24, height: 24))
            container.addSubview(button)
            for count in [8, 16, 24] {
                let menu = RecordingMenu()
                for index in 0..<count {
                    menu.addItem(withTitle: "Option \(index)", action: nil, keyEquivalent: "")
                }
                OptionsMenuPresentation.popUp(menu, from: button)
                precondition(menu.didPresent, "The menu must open.")
                precondition(menu.presentedView == nil, "A popover view reintroduces menu clipping.")
                precondition(menu.presentedPoint == NSPoint(x: window.frame.minX + 230, y: window.frame.minY + 66),
                             "The anchor must use screen coordinates, including nested view offsets.")
                precondition(menu.numberOfItems == count, "Presentation must preserve every item.")
            }
        }
        let detachedMenu = RecordingMenu()
        OptionsMenuPresentation.popUp(detachedMenu, from: NSButton())
        precondition(!detachedMenu.didPresent, "An unattached button has no valid screen anchor.")
        print("Menu presentation: screen anchoring and growth regression checks passed.")
    }
}
