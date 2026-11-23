import AppKit

protocol PlayerViewControllerDelegate: AnyObject {
    /// Go to the library to choose something else for this picture.
    func playerDidRequestLibrary(_ player: PlayerViewController)
    /// Stop this picture.
    func playerDidRequestClose(_ player: PlayerViewController)
    /// The film or episode in this picture played to its end.
    func playerDidFinish(_ player: PlayerViewController)
    /// Play the next (+1) or previous (-1) entry of the list it was chosen from.
    func playerDidRequestNeighbor(_ player: PlayerViewController, offset: Int)
    /// The speaker button: give this picture the sound, or mute it.
    func playerDidRequestAudio(_ player: PlayerViewController)
    /// A click on the picture: the sound follows.
    func playerDidRequestFocus(_ player: PlayerViewController)
    /// Put another channel beside this one.
    func playerDidRequestAdd(_ player: PlayerViewController)
    func playerDidChangeVolume(_ player: PlayerViewController)
    /// Keys go to one picture at a time.
    func playerIsKeyTarget(_ player: PlayerViewController) -> Bool
    func playerCanAdd(_ player: PlayerViewController) -> Bool
    /// False while another picture is showing its controls.
    func playerMayHideChrome(_ player: PlayerViewController) -> Bool
}

/// The picture, and nothing else, until the mouse moves.
///
/// While the mouse is still the window shows only the video, edge to edge:
/// no title bar, no window buttons, no controls, no cursor. Moving the mouse,
/// clicking or pressing a key brings a control bar up over the picture, and
/// it fades again after a short pause.
final class PlayerViewController: NSViewController, PlayerEngineDelegate {

    let engine = PlayerEngine()
    weak var delegate: PlayerViewControllerDelegate?

    /// True while the player, not the library, is what the window shows.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                noteActivity()
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self = self, self.controlsVisible else { return }
                    self.refresh()
                }
                RunLoop.main.add(t, forMode: .common)
                clockTimer = t
            } else {
                clockTimer?.invalidate()
                clockTimer = nil
                hideTimer?.invalidate()
                hideTimer = nil
                setControls(visible: false, animated: false)
                setWindowButtons(hidden: false)
                NSCursor.setHiddenUntilMouseMoves(false)
            }
        }
    }

    private static let awakeSeconds: TimeInterval = 2.5

    private let bar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let messageStack = NSStackView()
    private var libraryButton = NSButton()
    private var playButton = NSButton()
    private var muteButton = NSButton()
    private var stopButton = NSButton()
    private var addButton = NSButton()
    private var recordButton = NSButton()
    private let volumeSlider = NSSlider(value: 80, minValue: 0, maxValue: 100, target: nil, action: nil)

    private var hideTimer: Timer?
    private var clockTimer: Timer?
    private(set) var controlsVisible = false
    private var monitor: Any?

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        clockTimer?.invalidate()
        hideTimer?.invalidate()
    }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        view = root

        engine.delegate = self
        engine.view.frame = root.bounds
        engine.view.autoresizingMask = [.width, .height]
        root.addSubview(engine.view)

        buildMessage(in: root)
        buildBar(in: root)

        let config = ConfigStore.shared.config
        engine.volume = config.volume
        engine.muted = config.muted
        volumeSlider.integerValue = config.volume
        addButton.isHidden = true

        setControls(visible: false, animated: false)
        refresh()
        installMonitor()
    }

    private func buildMessage(in root: NSView) {
        messageLabel.font = NSFont.systemFont(ofSize: 20, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping

        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large

        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 14
        messageStack.addArrangedSubview(messageLabel)
        messageStack.addArrangedSubview(retryButton)
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.wantsLayer = true
        messageStack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        messageStack.layer?.cornerRadius = 10
        messageStack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 24)
        root.addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.8),
        ])
    }

    private func buildBar(in root: NSView) {
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        // Back to the library sits on its own at the top left, in the
        // app's gold, where it is seen first. It comes and goes with the
        // bar, so a still mouse leaves only the picture.
        let back = PillButton("Library", look: .primary, symbol: "chevron.left",
                              target: self, action: #selector(libraryPressed))
        back.toolTip = "Back to the library (Esc)"
        back.refusesFirstResponder = true
        back.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        libraryButton = back
        root.addSubview(back)
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            // below the window's own three buttons
            back.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
        ])
        playButton = symbolButton("pause.fill", fallback: "Pause", tip: "Play or pause (Space)",
                                  action: #selector(playPressed))
        muteButton = symbolButton("speaker.wave.2.fill", fallback: "Mute", tip: "Mute (M)",
                                  action: #selector(mutePressed))
        stopButton = symbolButton("stop.fill", fallback: "Stop", tip: "Stop",
                                  action: #selector(stopPressed))
        recordButton = symbolButton("record.circle", fallback: "Record",
                                    tip: "Record this channel to your Movies folder",
                                    action: #selector(recordPressed))
        addButton = symbolButton("plus.rectangle.on.rectangle", fallback: "Add",
                                 tip: "Watch another channel beside this one",
                                 action: #selector(addPressed))

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.toolTip = "Volume"
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let row = NSStackView(views: [titleLabel, statusLabel,
                                      playButton, muteButton, volumeSlider, recordButton, addButton, stopButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 56),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
    }

    private func symbolButton(_ symbol: String, fallback: String, tip: String, action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: fallback, target: self, action: action)
        }
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = tip
        button.setAccessibilityLabel(fallback)
        button.setContentHuggingPriority(.required, for: .horizontal)
        // Space is play/pause for the whole window. A button that kept the
        // keyboard focus would swallow it.
        button.refusesFirstResponder = true
        return button
    }

    private func setSymbol(_ button: NSButton, _ symbol: String, _ label: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button.image = image
        } else {
            button.title = label
        }
        button.setAccessibilityLabel(label)
    }

    // MARK: - Playing

    func play(_ item: PlayItem) {
        titleLabel.stringValue = item.title
        engine.play(item)
        refresh()
        noteActivity()
    }

    func stop() {
        engine.stop()
        refresh()
    }

    func togglePause() {
        engine.togglePause()
        noteActivity()
    }

    func toggleMute() {
        delegate?.playerDidRequestAudio(self)
        noteActivity()
    }

    /// The window changed who has the sound, or how loud it is.
    func syncAudio() {
        volumeSlider.integerValue = ConfigStore.shared.config.volume
        refresh()
    }

    func playerEngineDidChange(_ engine: PlayerEngine) {
        refresh()
        if engine.status == .ended {
            // Not from inside the engine's own change notice: going back to
            // the library stops the engine, which changes its status again.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.engine.status == .ended else { return }
                self.delegate?.playerDidFinish(self)
            }
        }
    }

    /// "  12:34 / 1:45:00" for a film or an episode, empty for a live channel.
    private func place() -> String {
        guard let item = engine.item else { return "" }
        if item.isLive {
            guard let line = GuideStore.shared.line(guideID: item.guideID, name: item.title) else { return "" }
            return "  ·  \(line)"
        }
        guard engine.positionMs > 0 else { return "" }
        let at = PlayerViewController.clock(engine.positionMs)
        if engine.lengthMs > 0 {
            return "  \(at) / \(PlayerViewController.clock(engine.lengthMs))"
        }
        return "  \(at)"
    }

    private static func clock(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    func skip(byMs delta: Int) {
        engine.skip(byMs: delta)
        refresh()
        noteActivity()
    }

    func startOver() {
        engine.seek(toMs: 0)
        refresh()
        noteActivity()
    }

    private func refresh() {
        var message = ""
        var showRetry = false
        var short = ""
        switch engine.status {
        case .idle, .ended:
            break
        case .opening:
            message = "Tuning…"
            short = "Tuning"
        case .playing:
            short = engine.item?.isLive == true ? "Live" : "Playing"
            short += place()
        case .paused:
            message = "Paused"
            short = "Paused" + place()
        case .reconnecting(let attempt):
            message = attempt > 1 ? "Reconnecting… (try \(attempt))" : "Reconnecting…"
            short = "Reconnecting"
        case .failed(let why):
            message = why
            short = "No signal"
            showRetry = true
        }
        messageLabel.stringValue = message
        retryButton.isHidden = !showRetry
        messageStack.isHidden = message.isEmpty
        statusLabel.stringValue = short

        let paused = engine.status == .paused
        setSymbol(playButton, paused ? "play.fill" : "pause.fill", paused ? "Play" : "Pause")
        setSymbol(muteButton, engine.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                  engine.muted ? "Unmute" : "Mute")
        addButton.isHidden = !(delegate?.playerCanAdd(self) ?? false)
        recordButton.isHidden = engine.item?.isLive != true
        recordButton.contentTintColor = engine.isRecording ? .systemRed : .white
        recordButton.toolTip = engine.isRecording ? "Stop recording"
            : "Record this channel to your Movies folder"
        if engine.isRecording { statusLabel.stringValue = "● REC  " + statusLabel.stringValue }
        if showRetry { noteActivity() }
    }

    // MARK: - Buttons

    @objc private func libraryPressed() { delegate?.playerDidRequestLibrary(self) }
    @objc private func stopPressed() { delegate?.playerDidRequestClose(self) }
    @objc private func addPressed() { delegate?.playerDidRequestAdd(self) }
    @objc private func recordPressed() { toggleRecording() }

    /// Start saving this channel to a file, or stop.
    func toggleRecording() {
        if engine.isRecording {
            engine.stopRecording()
        } else if let item = engine.item, item.isLive {
            if !engine.startRecording(stage: Recordings.newStage(title: item.title)) {
                NSSound.beep()
            }
        } else {
            NSSound.beep()
        }
        refresh()
        noteActivity()
    }
    @objc private func playPressed() { togglePause() }
    @objc private func mutePressed() { toggleMute() }

    @objc private func retryPressed() {
        engine.retryNow()
        refresh()
    }

    @objc private func volumeChanged() {
        let value = volumeSlider.integerValue
        ConfigStore.shared.update { $0.volume = value }
        delegate?.playerDidChangeVolume(self)
    }

    // MARK: - Awake and asleep

    /// The mouse moved or a key was pressed: show the controls, and start
    /// counting down to hiding them again.
    func noteActivity() {
        guard isActive else { return }
        setControls(visible: true, animated: true)
        setWindowButtons(hidden: false)
        hideTimer?.invalidate()
        let t = Timer(timeInterval: PlayerViewController.awakeSeconds, repeats: false) { [weak self] _ in
            self?.doze()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    private func doze() {
        hideTimer = nil
        guard isActive else { return }
        // Nothing slides away while it is being used or while it has
        // something to say.
        if mouseIsOverBar() || engineNeedsAttention() {
            noteActivity()
            return
        }
        setControls(visible: false, animated: true)
        // The window's own buttons and the cursor stay while another
        // picture still has its controls up.
        guard delegate?.playerMayHideChrome(self) ?? true else { return }
        setWindowButtons(hidden: true)
        if view.window?.isKeyWindow == true {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    /// The mouse went to another picture: this one's controls go at once.
    private func sleepNow() {
        hideTimer?.invalidate()
        hideTimer = nil
        setControls(visible: false, animated: true)
    }

    private func mouseIsInside() -> Bool {
        guard let window = view.window else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.bounds.contains(point)
    }

    /// True while the mouse is over this picture.
    var isUnderMouse: Bool { mouseIsInside() }

    private func engineNeedsAttention() -> Bool {
        if case .failed = engine.status { return true }
        return false
    }

    private func mouseIsOverBar() -> Bool {
        guard let window = view.window else { return false }
        let point = bar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bar.bounds.contains(point) { return true }
        let other = libraryButton.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return libraryButton.bounds.insetBy(dx: -10, dy: -10).contains(other)
    }

    /// For the picture the cloud build takes of the player.
    func showControlsForPicture() {
        setControls(visible: true, animated: false)
    }

    private func setControls(visible: Bool, animated: Bool) {
        guard visible != controlsVisible || !animated else { return }
        controlsVisible = visible
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                bar.animator().alphaValue = visible ? 1 : 0
                libraryButton.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            bar.alphaValue = visible ? 1 : 0
            libraryButton.alphaValue = visible ? 1 : 0
        }
    }

    private func setWindowButtons(hidden: Bool) {
        guard let window = view.window else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = hidden
        }
    }

    // MARK: - Mouse and keys

    private func installMonitor() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                           .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self, self.isActive, event.window === self.view.window else {
                return event
            }
            if event.type == .keyDown {
                // keys go to one picture: the one under the mouse, or the
                // one with the sound
                guard self.delegate?.playerIsKeyTarget(self) ?? true else { return event }
                self.noteActivity()
                return self.handleKey(event) ? nil : event
            }
            guard self.mouseIsInside() else {
                if self.controlsVisible && !self.engineNeedsAttention() { self.sleepNow() }
                return event
            }
            self.noteActivity()
            if event.type == .leftMouseDown && !self.mouseIsOverBar() {
                if event.clickCount == 2 {
                    self.view.window?.toggleFullScreen(nil)
                    return nil
                }
                self.delegate?.playerDidRequestFocus(self)
            }
            return event
        }
    }

    /// Returns true when the key was used.
    private func handleKey(_ event: NSEvent) -> Bool {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        if !event.modifierFlags.intersection(blocked).isEmpty { return false }
        if view.window?.firstResponder is NSText { return false }

        switch event.keyCode {
        case 49: // space
            togglePause()
            return true
        case 53: // escape
            if view.window?.styleMask.contains(.fullScreen) == true {
                view.window?.toggleFullScreen(nil)
            } else {
                delegate?.playerDidRequestLibrary(self)
            }
            return true
        case 126: // up
            delegate?.playerDidRequestNeighbor(self, offset: -1)
            return true
        case 125: // down
            delegate?.playerDidRequestNeighbor(self, offset: 1)
            return true
        case 123: // left
            guard engine.item?.isLive == false else { return false }
            skip(byMs: -10_000)
            return true
        case 124: // right
            guard engine.item?.isLive == false else { return false }
            skip(byMs: 30_000)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m":
            toggleMute()
            return true
        case "f":
            view.window?.toggleFullScreen(nil)
            return true
        default:
            return false
        }
    }
}
