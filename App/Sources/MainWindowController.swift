import AppKit
import TuberCore

/// The one window. It shows either the library or the pictures, never a mix.
///
/// Both exist the whole time and one is hidden. Nothing is saved and
/// restored when switching between them, so the library is found exactly as
/// it was left: same search, same row, same scroll position.
///
/// Up to four channels can play at once, as many as the provider's plan
/// allows. Each picture has its own controls, shown while the mouse is over
/// it. One picture has the sound at a time.
final class MainWindowController: NSWindowController, NSWindowDelegate,
                                  LibraryViewControllerDelegate, PlayerViewControllerDelegate {

    let library = LibraryViewController()
    var onSettings: (() -> Void)?

    private let wall = WallView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    private let container = NSViewController()
    /// The pictures. There is always at least one, even while it is idle.
    private(set) var tiles: [PlayerViewController] = []
    private var playing: [ObjectIdentifier: Channel] = [:]
    private var audioTile: PlayerViewController
    private var resumeTimer: Timer?

    /// What the library is being asked to choose for, while the pictures
    /// keep playing behind it.
    private enum Pick {
        case add
        case replace(PlayerViewController)
    }
    private var pick: Pick?

    private static let frameName = "TuberViewMainWindow"

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "TuberView"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        window.minSize = NSSize(width: 720, height: 420)
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false

        let first = PlayerViewController()
        audioTile = first
        super.init(window: window)
        window.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        container.view = root
        container.addChild(library)
        library.view.frame = root.bounds
        library.view.autoresizingMask = [.width, .height]
        root.addSubview(library.view)
        wall.frame = root.bounds
        wall.autoresizingMask = [.width, .height]
        wall.isHidden = true
        root.addSubview(wall)
        window.contentViewController = container

        library.delegate = self
        adopt(first)

        if !window.setFrameUsingName(MainWindowController.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(MainWindowController.frameName)
    }

    required init?(coder: NSCoder) {
        fatalError("MainWindowController is built in code")
    }

    // MARK: - The pictures

    /// How many channels may play at once.
    private var limit: Int {
        max(1, min(4, ConfigStore.shared.config.maxStreams))
    }

    private func adopt(_ tile: PlayerViewController) {
        tile.delegate = self
        container.addChild(tile)
        tile.view.autoresizingMask = []
        wall.addSubview(tile.view)
        tiles.append(tile)
        wall.tiles = tiles.map(\.view)
    }

    private func close(_ tile: PlayerViewController) {
        guard tiles.count > 1, let i = tiles.firstIndex(where: { $0 === tile }) else { return }
        saveResume(tile)
        tile.stop()
        tile.isActive = false
        tile.view.removeFromSuperview()
        tile.removeFromParent()
        tiles.remove(at: i)
        playing[ObjectIdentifier(tile)] = nil
        if audioTile === tile { audioTile = tiles[0] }
        arrange()
        applyAudio()
    }

    /// The picture that keys and menu commands act on: the one under the
    /// mouse, otherwise the one with the sound.
    var player: PlayerViewController {
        if isWatching, let under = tiles.first(where: { $0.isUnderMouse }) { return under }
        return audioTile
    }

    var engines: [PlayerEngine] { tiles.map(\.engine) }

    /// True while the pictures, not the library, are what the window shows.
    var isWatching: Bool { !wall.isHidden }

    private var hasStreams: Bool { tiles.contains { $0.engine.item != nil } }

    /// What is on in the picture commands act on, if anything.
    var nowPlaying: Channel? { playing[ObjectIdentifier(player)] }

    var canAddPicture: Bool { isWatching && tiles.count < limit }

    /// The window as it was before it took the shape of several pictures.
    private var frameBeforeWall: NSRect?

    /// Lay the pictures out, and give the window their shape so they fill
    /// it exactly, with no bars around them. With one picture, or in the
    /// library, the window goes back to the size it had.
    private func arrange() {
        wall.tiles = tiles.map(\.view)
        guard let window = window, !window.styleMask.contains(.fullScreen) else { return }
        // let go of the last shape before changing size
        window.resizeIncrements = NSSize(width: 1, height: 1)
        guard isWatching && tiles.count > 1 else {
            window.minSize = NSSize(width: 720, height: 420)
            if let frame = frameBeforeWall {
                frameBeforeWall = nil
                window.setFrame(frame, display: true, animate: false)
            }
            return
        }
        if frameBeforeWall == nil { frameBeforeWall = window.frame }
        let grid = WallView.grid(for: tiles.count)
        let ratio = (CGFloat(grid.columns) * 16) / (CGFloat(grid.rows) * 9)
        let least = NSSize(width: 480 * CGFloat(grid.columns), height: 270 * CGFloat(grid.rows))
        let room = window.screen?.visibleFrame
        // Keep the width or keep the height, whichever leaves the pictures
        // bigger once it fits the screen.
        func fitted(_ width: CGFloat) -> NSSize {
            var w = max(width, least.width)
            if let room = room { w = min(w, room.width, room.height * ratio) }
            w = w.rounded()
            return NSSize(width: w, height: (w / ratio).rounded())
        }
        var frame = window.frame
        let top = frame.maxY
        let a = fitted(frame.width)
        let b = fitted(frame.height * ratio)
        frame.size = a.width >= b.width ? a : b
        frame.origin.y = top - frame.height
        if let room = room {
            if frame.maxX > room.maxX { frame.origin.x = room.maxX - frame.width }
            if frame.minX < room.minX { frame.origin.x = room.minX }
            if frame.minY < room.minY { frame.origin.y = room.minY }
            if frame.maxY > room.maxY { frame.origin.y = room.maxY - frame.height }
        }
        window.minSize = least
        window.setFrame(frame, display: true, animate: false)
        window.aspectRatio = NSSize(width: CGFloat(grid.columns) * 16, height: CGFloat(grid.rows) * 9)
    }

    /// One picture has the sound; every picture shows the same volume.
    private func applyAudio() {
        let config = ConfigStore.shared.config
        for tile in tiles {
            tile.engine.volume = config.volume
            tile.engine.muted = config.muted || tile !== audioTile
            tile.syncAudio()
        }
    }

    // MARK: - Switching

    /// Play a channel: in the picture the library was opened for, or as the
    /// only picture when it was chosen the ordinary way.
    func play(_ channel: Channel) {
        let chosen = pick
        pick = nil
        library.pickMessage = nil
        var target = tiles[0]
        switch chosen {
        case .replace(let tile)? where tiles.contains(where: { $0 === tile }):
            target = tile
        case .add? where hasStreams && tiles.count < limit:
            let tile = PlayerViewController()
            adopt(tile)
            target = tile
            audioTile = tile
        case .add? where hasStreams:
            target = audioTile
        default:
            // chosen from the library with nothing else wanted: one picture
            for extra in tiles.dropFirst().reversed() { close(extra) }
            target = tiles[0]
            audioTile = target
        }
        start(channel, in: target)
        showWall()
    }

    private func start(_ channel: Channel, in tile: PlayerViewController) {
        saveResume(tile)
        playing[ObjectIdentifier(tile)] = channel
        var item = PlayItem(title: channel.name, url: channel.url, isLive: channel.kind == .live)
        if channel.kind != .live {
            item.startMs = ResumePoints.shared.position(for: channel.url)
        }
        item.guideID = channel.guideID
        tile.play(item)
        startResumeTimer()
    }

    private func showWall() {
        library.view.isHidden = true
        wall.isHidden = false
        for tile in tiles { tile.isActive = true }
        // Take the keyboard away from the search box, so Space and the
        // arrows reach the pictures.
        window?.makeFirstResponder(nil)
        arrange()
        applyAudio()
    }

    /// Stop every picture and show the library, as it was left.
    func showLibrary() {
        saveResume()
        resumeTimer?.invalidate()
        resumeTimer = nil
        pick = nil
        library.pickMessage = nil
        for extra in tiles.dropFirst().reversed() { close(extra) }
        tiles[0].stop()
        playing.removeAll()
        audioTile = tiles[0]
        guard isWatching || library.view.isHidden else { return }
        for tile in tiles { tile.isActive = false }
        wall.isHidden = true
        library.view.isHidden = false
        arrange()
        library.focusList()
    }

    /// Show the library to choose a channel while the pictures keep going.
    private func beginPick(_ what: Pick, message: String) {
        pick = what
        for tile in tiles { tile.isActive = false }
        wall.isHidden = true
        library.view.isHidden = false
        library.pickMessage = message
        arrange()
        library.focusList()
    }

    /// Put another channel beside the ones playing.
    func addPicture() {
        guard canAddPicture else {
            NSSound.beep()
            return
        }
        beginPick(.add, message: "Choose a channel to watch beside the one playing. Esc goes back.")
    }

    func playNeighbor(offset: Int) {
        let tile = player
        guard let current = playing[ObjectIdentifier(tile)],
              let next = library.neighbor(of: current, offset: offset) else {
            NSSound.beep()
            return
        }
        library.select(next)
        start(next, in: tile)
    }

    func focusSearch() {
        if isWatching { showLibrary() }
        library.focusSearch()
    }

    func toggleMute() {
        ConfigStore.shared.update { $0.muted.toggle() }
        applyAudio()
    }

    func stopAll() {
        saveResume()
        for tile in tiles { tile.stop() }
        restoreShape()
    }

    /// Before the window's place is remembered for next time, put it back
    /// to the size it had before several pictures reshaped it.
    private func restoreShape() {
        guard let window = window, let frame = frameBeforeWall,
              !window.styleMask.contains(.fullScreen) else { return }
        frameBeforeWall = nil
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.minSize = NSSize(width: 720, height: 420)
        window.setFrame(frame, display: false, animate: false)
        window.saveFrame(usingName: MainWindowController.frameName)
    }

    // MARK: - Favorites

    /// What a favorites command acts on: the picture while watching,
    /// otherwise the highlighted row.
    var favoriteTarget: Channel? {
        isWatching ? nowPlaying : library.highlighted
    }

    func toggleFavorite() {
        guard let channel = favoriteTarget else {
            NSSound.beep()
            return
        }
        Favorites.shared.toggle(channel)
    }

    // MARK: - Films and episodes

    /// True while a film or an episode, not a live channel, is in the
    /// picture commands act on.
    var isWatchingFilm: Bool {
        guard isWatching, let channel = nowPlaying else { return false }
        return channel.kind != .live
    }

    func skip(byMs delta: Int) {
        guard isWatchingFilm else { return }
        player.skip(byMs: delta)
    }

    func startOver() {
        guard isWatchingFilm, let channel = nowPlaying else { return }
        ResumePoints.shared.forget(url: channel.url)
        player.startOver()
    }

    /// Remember where every film or episode on screen has got to.
    func saveResume() {
        for tile in tiles { saveResume(tile) }
    }

    /// One that played to its end is forgotten, so it starts from the top
    /// next time.
    private func saveResume(_ tile: PlayerViewController) {
        guard let channel = playing[ObjectIdentifier(tile)], channel.kind != .live else { return }
        let engine = tile.engine
        if engine.status == .ended {
            ResumePoints.shared.forget(url: channel.url)
            Recents.shared.forget(url: channel.url)
            return
        }
        guard engine.item != nil, engine.positionMs > 0 else { return }
        ResumePoints.shared.record(url: channel.url, positionMs: engine.positionMs,
                                   lengthMs: engine.lengthMs)
        Recents.shared.note(url: channel.url, positionMs: engine.positionMs,
                            lengthMs: engine.lengthMs)
    }

    private func startResumeTimer() {
        guard resumeTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.saveResume()
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    // MARK: - Library

    func library(_ library: LibraryViewController, didChoose channel: Channel) {
        play(channel)
    }

    func libraryDidRequestSettings(_ library: LibraryViewController) {
        onSettings?()
    }

    func libraryDidCancelPick(_ library: LibraryViewController) {
        guard pick != nil else { return }
        pick = nil
        library.pickMessage = nil
        if hasStreams {
            showWall()
        }
    }

    // MARK: - Pictures

    func playerDidRequestLibrary(_ player: PlayerViewController) {
        if tiles.count > 1 {
            beginPick(.replace(player),
                      message: "Choose a channel for that picture. The others keep playing. Esc goes back.")
        } else {
            showLibrary()
        }
    }

    func playerDidRequestClose(_ player: PlayerViewController) {
        if tiles.count > 1 {
            close(player)
        } else {
            showLibrary()
        }
    }

    func playerDidFinish(_ player: PlayerViewController) {
        saveResume(player)
        if tiles.count > 1 {
            close(player)
        } else {
            showLibrary()
        }
    }

    func playerDidRequestNeighbor(_ player: PlayerViewController, offset: Int) {
        playNeighbor(offset: offset)
    }

    func playerDidRequestAudio(_ player: PlayerViewController) {
        if player === audioTile {
            ConfigStore.shared.update { $0.muted.toggle() }
        } else {
            audioTile = player
            ConfigStore.shared.update { $0.muted = false }
        }
        applyAudio()
    }

    func playerDidRequestFocus(_ player: PlayerViewController) {
        guard player !== audioTile else { return }
        audioTile = player
        applyAudio()
    }

    func playerDidRequestAdd(_ player: PlayerViewController) {
        addPicture()
    }

    func playerDidChangeVolume(_ player: PlayerViewController) {
        if ConfigStore.shared.config.muted && ConfigStore.shared.config.volume > 0 {
            ConfigStore.shared.update { $0.muted = false }
        }
        applyAudio()
    }

    func playerIsKeyTarget(_ player: PlayerViewController) -> Bool {
        player === self.player
    }

    func playerCanAdd(_ player: PlayerViewController) -> Bool {
        tiles.count < limit
    }

    func playerMayHideChrome(_ player: PlayerViewController) -> Bool {
        !tiles.contains { $0 !== player && $0.controlsVisible }
    }

    // MARK: - Window

    func windowDidExitFullScreen(_ notification: Notification) {
        arrange()
    }

    func windowWillClose(_ notification: Notification) {
        saveResume()
        resumeTimer?.invalidate()
        resumeTimer = nil
        for tile in tiles { tile.stop() }
        playing.removeAll()
        restoreShape()
    }
}
