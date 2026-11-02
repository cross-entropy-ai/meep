import AppKit

/// Menu bar icons from the app bundle's SVGs (assets/*.svg, copied by build.sh).
enum MenuBarIcons {
    static let size = NSSize(width: 18, height: 18)

    /// Idle: follows the menu bar's light/dark appearance.
    static let idle = template("microphone")
    /// Saving / post-processing.
    static let saving = template("loader")
    /// Recording: the record icon lit up in red.
    static let recording = tinted("player-record", .systemRed)
    /// Recording, but a track is being recovered (device switch / stall).
    static let recovering = tinted("player-record", .systemOrange)

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = size
        return img
    }

    private static func template(_ name: String) -> NSImage? {
        let img = load(name)
        img?.isTemplate = true
        return img
    }

    /// A fixed-color copy (not a template, so the menu bar does not recolor it).
    private static func tinted(_ name: String, _ color: NSColor) -> NSImage? {
        guard let base = load(name) else { return nil }
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
