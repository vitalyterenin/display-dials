import AppKit

@MainActor
enum OptionsMenuPresentation {
    static func popUp(_ menu: NSMenu, from button: NSButton) {
        guard let window = button.window else { return }
        let bounds = button.convert(button.bounds, to: nil)
        let anchor = NSPoint(x: bounds.minX, y: bounds.minY - 4)
        let screenPoint = window.convertPoint(toScreen: anchor)
        // A popover view makes AppKit constrain menus to the popover's height.
        // A screen-space popup lets AppKit size and position any number of items.
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
    }
}
