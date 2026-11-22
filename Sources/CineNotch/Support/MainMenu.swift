import AppKit

/// CineNotch is an accessory (menu bar) app, so AppKit never installs a main menu.
/// Without an Edit menu, the standard key equivalents (Cmd+V, Cmd+C, and the rest)
/// never reach text fields, including the license key in Settings. The menu stays
/// hidden because the activation policy is still accessory; items target the first
/// responder through the usual nil-targeted selectors.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        // The first submenu is the application menu. Accessory apps don't show it
        // in the menu bar, but AppKit still treats it as the app menu, so Edit
        // has to come second.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
