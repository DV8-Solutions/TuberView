import AppKit
import TuberCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var main: MainWindowController?
    private lazy var settings = SettingsWindowController()
    private let power = PowerMonitor()
    private var selfTest: SelfTest?
    private var snapshot: Snapshot?

    // MARK: - Life cycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()

        let main = MainWindowController()
        main.onSettings = { [weak self] in self?.showSettings(nil) }
        self.main = main
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        power.onWillSleep = { [weak self] in
            self?.main?.engines.forEach { $0.prepareForSleep() }
        }
        power.onDidWake = { [weak self] in
            self?.main?.engines.forEach { $0.didWake() }
        }
        power.onNetworkChange = { [weak self] available in
            self?.main?.engines.forEach { $0.networkChanged(available: available) }
        }
        // The cloud build's own check. It plays one public test stream and
        // touches neither the playlist nor the settings.
        if let address = SelfTest.requestedAddress() {
            let test = SelfTest(main: main, address: address)
            selfTest = test
            test.start()
            return
        }

        power.start()
        Recordings.collectLeftovers()

        // Pictures of the library for review. With made-up data nothing
        // real is read or fetched.
        if let folder = Snapshot.folder {
            let shot = Snapshot(main: main, folder: folder)
            snapshot = shot
            if Snapshot.demo {
                shot.installDemo()
            } else {
                Library.shared.start()
                GuideStore.shared.start()
            }
            shot.start()
            return
        }

        Library.shared.start()
        GuideStore.shared.start()
        if !Library.shared.hasSource {
            showSettings(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        main?.stopAll()
        power.stop()
        ConfigStore.shared.flush()
        Favorites.shared.flush()
        ResumePoints.shared.flush()
        Recents.shared.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "Video playback by VLCKit, © VideoLAN, used under the LGPL 2.1.\n\nThe Top 10 rows can use the TMDB API. TuberView is not endorsed or certified by TMDB.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        settings.present()
    }

    @objc func refreshChannels(_ sender: Any?) {
        if Library.shared.hasSource {
            Library.shared.refresh()
        } else {
            showSettings(nil)
        }
    }

    @objc func togglePlayPause(_ sender: Any?) {
        guard let main = main, main.isWatching else { return }
        main.player.togglePause()
    }

    @objc func stopPlayback(_ sender: Any?) {
        main?.showLibrary()
    }

    @objc func toggleMute(_ sender: Any?) {
        main?.toggleMute()
    }

    @objc func nextChannel(_ sender: Any?) {
        guard let main = main, main.isWatching else { return }
        main.playNeighbor(offset: 1)
    }

    @objc func previousChannel(_ sender: Any?) {
        guard let main = main, main.isWatching else { return }
        main.playNeighbor(offset: -1)
    }

    @objc func toggleFavorite(_ sender: Any?) {
        main?.toggleFavorite()
    }

    @objc func addPicture(_ sender: Any?) {
        main?.addPicture()
    }

    @objc func toggleRecording(_ sender: Any?) {
        guard let main = main, main.isWatching else { return }
        main.player.toggleRecording()
    }

    @objc func showRecordings(_ sender: Any?) {
        NSWorkspace.shared.open(Recordings.folder)
    }

    @objc func skipBack(_ sender: Any?) {
        main?.skip(byMs: -10_000)
    }

    @objc func skipForward(_ sender: Any?) {
        main?.skip(byMs: 30_000)
    }

    @objc func startOver(_ sender: Any?) {
        main?.startOver()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(toggleFavorite(_:)):
            guard let channel = main?.favoriteTarget else {
                menuItem.title = "Add to Favorites"
                return false
            }
            menuItem.title = Favorites.shared.contains(channel)
                ? "Remove from Favorites" : "Add to Favorites"
            return true
        case #selector(toggleRecording(_:)):
            guard let main = main, main.isWatching, main.nowPlaying?.kind == .live else {
                menuItem.title = "Record"
                return false
            }
            menuItem.title = main.player.engine.isRecording ? "Stop Recording" : "Record"
            return true
        case #selector(addPicture(_:)):
            return main?.canAddPicture == true
        case #selector(skipBack(_:)), #selector(skipForward(_:)), #selector(startOver(_:)):
            return main?.isWatchingFilm == true
        case #selector(togglePlayPause(_:)), #selector(nextChannel(_:)), #selector(previousChannel(_:)),
             #selector(stopPlayback(_:)):
            return main?.isWatching == true
        default:
            return true
        }
    }

    @objc func showLibrary(_ sender: Any?) {
        main?.showLibrary()
        main?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func focusSearch(_ sender: Any?) {
        main?.window?.makeKeyAndOrderFront(nil)
        main?.focusSearch()
    }

    // MARK: - Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "",
                      _ modifiers: NSEvent.ModifierFlags = [.command],
                      target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private func submenu(_ title: String, in bar: NSMenu) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        bar.addItem(holder)
        return menu
    }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu(title: "Main Menu")

        // TuberView
        let app = submenu("TuberView", in: bar)
        app.addItem(item("About TuberView", #selector(showAbout(_:)), target: self))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings(_:)), ",", target: self))
        app.addItem(item("Refresh Channels", #selector(refreshChannels(_:)), "r", target: self))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item("Hide TuberView", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
                         [.command, .option]))
        app.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item("Quit TuberView", #selector(NSApplication.terminate(_:)), "q"))

        // Edit, so copy and paste work in the search box and in Settings
        let edit = submenu("Edit", in: bar)
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))

        // Playback
        let playback = submenu("Playback", in: bar)
        playback.addItem(item("Play or Pause", #selector(togglePlayPause(_:)), "p", target: self))
        playback.addItem(item("Stop", #selector(stopPlayback(_:)), ".", target: self))
        playback.addItem(item("Mute", #selector(toggleMute(_:)), "m", [.command, .shift], target: self))
        playback.addItem(.separator())
        playback.addItem(item("Next Channel", #selector(nextChannel(_:)), "\u{F701}", target: self))
        playback.addItem(item("Previous Channel", #selector(previousChannel(_:)), "\u{F700}", target: self))
        playback.addItem(.separator())
        playback.addItem(item("Skip Back 10 Seconds", #selector(skipBack(_:)), target: self))
        playback.addItem(item("Skip Forward 30 Seconds", #selector(skipForward(_:)), target: self))
        playback.addItem(item("Start from Beginning", #selector(startOver(_:)), target: self))
        playback.addItem(.separator())
        playback.addItem(item("Add to Favorites", #selector(toggleFavorite(_:)), "d", target: self))
        playback.addItem(item("Watch Another Channel Beside This One", #selector(addPicture(_:)), "t",
                              target: self))
        playback.addItem(.separator())
        playback.addItem(item("Record", #selector(toggleRecording(_:)), "r", [.command, .shift],
                              target: self))
        playback.addItem(item("Show Recordings in Finder", #selector(showRecordings(_:)), target: self))

        // View
        let view = submenu("View", in: bar)
        view.addItem(item("Library", #selector(showLibrary(_:)), "l", target: self))
        view.addItem(item("Search", #selector(focusSearch(_:)), "f", target: self))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
                          [.command, .control]))

        // Window
        let window = submenu("Window", in: bar)
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window

        return bar
    }
}
