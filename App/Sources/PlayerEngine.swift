import AppKit
import TuberCore
import VLCKit

/// Something to play.
struct PlayItem: Equatable {
    let title: String
    let url: String
    /// A channel that never ends, as opposed to a film or an episode.
    let isLive: Bool
    /// Where to start a film or an episode, in milliseconds.
    var startMs = 0
    /// The channel's name in the guide, when the playlist gives one.
    var guideID = ""
}

protocol PlayerEngineDelegate: AnyObject {
    func playerEngineDidChange(_ engine: PlayerEngine)
}

/// One picture: plays a stream with VLC's engine and keeps it playing.
///
/// The engine never trusts a connection to stay alive. Twice a second it
/// checks that the stream is still moving; if it has frozen, ended early or
/// failed, the connection is thrown away and a new one is opened from the
/// original address. The same happens after the Mac wakes and when the
/// network changes. Each picture in a future multi-view gets its own engine.
///
/// Main thread only.
final class PlayerEngine {

    enum Status: Equatable {
        case idle
        case opening
        case playing
        case paused
        case reconnecting(attempt: Int)
        case ended
        case failed(String)
    }

    /// Put this view in the window. The picture is drawn inside it.
    let view: NSView

    weak var delegate: PlayerEngineDelegate?

    private(set) var item: PlayItem?
    private(set) var status: Status = .idle {
        didSet {
            if status != oldValue { delegate?.playerEngineDidChange(self) }
        }
    }

    /// 0 to 100.
    var volume: Int = 80 {
        didSet {
            volume = max(0, min(100, volume))
            applyAudio()
        }
    }
    var muted = false {
        didSet { applyAudio() }
    }

    // MARK: - State

    /// One connection to the provider and the view it draws into. A reconnect
    /// makes a whole new one instead of reusing a player that may be stuck.
    private final class Session {
        let player: VLCMediaPlayer
        let media: VLCMedia
        let videoView: VLCVideoView
        var recording = false

        init(player: VLCMediaPlayer, media: VLCMedia, videoView: VLCVideoView) {
            self.player = player
            self.media = media
            self.videoView = videoView
        }
    }

    private var session: Session?
    /// The user wants a picture. False once they stop, or the item finishes.
    private var wantPlaying = false
    private var userPaused = false
    /// Between "the Mac is going to sleep" and shortly after it wakes.
    private var sleeping = false
    /// Counts reconnects in a row. Back to 0 once a stream has held for a while.
    private var attempt = 0
    /// This item has shown a picture at least once since the user chose it.
    private var everPlayed = false
    private var audioApplied = false
    /// Where a film had got to, in milliseconds, so a reconnect resumes there.
    private var resumeMs = 0
    private var knownLengthMs = 0
    private var seekedAt: TimeInterval = 0

    /// While recording: the folder the files are written into until the
    /// recording is over. Each connection writes its own file there, so a
    /// reconnect never overwrites what was already saved.
    private var recordingStage: URL?
    var isRecording: Bool { recordingStage != nil }

    /// How far a film or an episode has got, and how long it is, in
    /// milliseconds. Both are 0 for a live channel or when not yet known.
    var positionMs: Int { resumeMs }
    var lengthMs: Int { knownLengthMs }
    private var startedAt: TimeInterval = 0
    /// After a network change, a freeze is acted on sooner.
    private var suspectUntil: TimeInterval = 0
    private var detector = StallDetector(now: 0)
    private var generation = 0
    private var retryWork: DispatchWorkItem?
    private var timer: Timer?

    private static func clock() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    init() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    deinit {
        timer?.invalidate()
        retryWork?.cancel()
        if let s = session { PlayerEngine.dispose(s) }
    }

    // MARK: - What the user asks for

    func play(_ newItem: PlayItem) {
        cancelRetry()
        item = newItem
        wantPlaying = true
        userPaused = false
        attempt = 0
        everPlayed = false
        resumeMs = newItem.isLive ? 0 : max(0, newItem.startMs)
        knownLengthMs = 0
        endRecording()
        suspectUntil = 0
        startTimer()
        open()
    }

    func stop() {
        cancelRetry()
        wantPlaying = false
        userPaused = false
        generation += 1
        if let s = detachSession() { PlayerEngine.dispose(s) }
        stopTimer()
        item = nil
        endRecording()
        status = .idle
    }

    // MARK: - Recording

    /// Save what this picture shows to files in `stage` as well as showing
    /// it. The same connection feeds both, so recording never uses a second
    /// stream from the provider, and the picture is not interrupted.
    @discardableResult
    func startRecording(stage: URL) -> Bool {
        guard wantPlaying, item != nil, recordingStage == nil else { return false }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        } catch {
            return false
        }
        recordingStage = stage
        Recordings.begin(stage)
        recordIfPlaying()
        delegate?.playerEngineDidChange(self)
        return true
    }

    func stopRecording() {
        guard recordingStage != nil else { return }
        endRecording()
        delegate?.playerEngineDidChange(self)
    }

    /// Stop writing, and give the files their proper names.
    private func endRecording() {
        guard let stage = recordingStage else { return }
        recordingStage = nil
        if let s = session, s.recording {
            s.recording = false
            _ = s.player.stopRecording()
        }
        Recordings.finish(stage)
    }

    /// A connection can only be recorded once it is delivering. Called when
    /// recording starts and whenever a connection starts playing, so a
    /// reconnect carries on into a new file.
    private func recordIfPlaying() {
        guard let stage = recordingStage, let s = session, !s.recording,
              s.player.isPlaying else { return }
        s.recording = true
        _ = s.player.startRecording(atPath: stage.path)
    }

    /// Jump to a place in a film or an episode. Live channels have no place.
    func seek(toMs target: Int) {
        guard wantPlaying, let item = item, !item.isLive else { return }
        var ms = max(0, target)
        if knownLengthMs > 0 { ms = min(ms, max(0, knownLengthMs - 5000)) }
        resumeMs = ms
        seekedAt = PlayerEngine.clock()
        if let s = session, s.player.isSeekable {
            s.player.time = VLCTime(int: Int32(clamping: ms))
        }
    }

    func skip(byMs delta: Int) {
        seek(toMs: resumeMs + delta)
    }

    func togglePause() {
        guard wantPlaying, let item = item else { return }
        if userPaused {
            userPaused = false
            if item.isLive || session == nil {
                // A paused channel's connection is stale. Go back to live.
                attempt = 0
                open()
            } else {
                session?.player.play()
                detector = StallDetector(now: PlayerEngine.clock())
                status = .opening
            }
        } else {
            guard let s = session else { return }
            rememberPosition(s)
            userPaused = true
            s.player.pause()
            status = .paused
        }
    }

    /// The user pressed Try Again after a failure.
    func retryNow() {
        guard item != nil else { return }
        cancelRetry()
        wantPlaying = true
        userPaused = false
        attempt = 0
        everPlayed = false
        startTimer()
        open()
    }

    // MARK: - What the Mac tells us

    /// The lid is closing. Let go of the connection now: it will be dead by
    /// the time the Mac wakes, and a dead one is what freezes other players.
    func prepareForSleep() {
        sleeping = true
        cancelRetry()
        generation += 1
        if let s = detachSession() {
            rememberPosition(s)
            PlayerEngine.dispose(s)
        }
        if wantPlaying && !userPaused { status = .opening }
    }

    /// The Mac woke. Give the network a moment, then start again from the
    /// original address so the provider hands out a fresh connection.
    func didWake() {
        sleeping = true
        cancelRetry()
        generation += 1
        if let s = detachSession() {
            rememberPosition(s)
            PlayerEngine.dispose(s)
        }
        if wantPlaying && !userPaused { status = .opening }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.sleeping = false
            guard self.wantPlaying, !self.userPaused else { return }
            self.attempt = 0
            // Wi-Fi can take a while to return. Keep trying, do not give up.
            self.everPlayed = true
            self.open()
        }
    }

    /// Wi-Fi came back, or the Mac moved to a different network.
    func networkChanged(available: Bool) {
        guard wantPlaying, !sleeping, !userPaused else { return }
        if available {
            if status == .playing {
                // The old connection is probably gone. Notice quickly if so.
                suspectUntil = PlayerEngine.clock() + 20
            } else if retryWork != nil {
                // Waiting between tries: there is no reason to wait any more.
                attempt = 0
                open()
            } else {
                // A connection is being opened right now on what may be the
                // old network. Do not let it sit for the full allowance.
                suspectUntil = PlayerEngine.clock() + 20
            }
        }
    }

    // MARK: - Opening and closing connections

    private func open() {
        cancelRetry()
        generation += 1
        let mine = generation
        status = attempt > 0 ? .reconnecting(attempt: attempt) : .opening

        guard let old = detachSession() else {
            startSession()
            return
        }
        // Let the old connection close before the new one opens, so a plan
        // that allows only a couple of streams is never over its limit. Do
        // not wait long: a dead connection can take its time to close.
        var begun = false
        let begin: () -> Void = { [weak self] in
            guard let self = self, !begun else { return }
            begun = true
            if mine == self.generation && self.wantPlaying && !self.sleeping {
                self.startSession()
            }
        }
        PlayerEngine.dispose(old, then: begin)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: begin)
    }

    private func startSession() {
        guard let item = item else { return }
        guard let url = PlayerEngine.streamURL(from: item.url) else {
            fail("This channel's address isn't valid.")
            return
        }
        guard let media = VLCMedia(url: url) as VLCMedia? else {
            fail("This channel couldn't be opened.")
            return
        }
        media.addOption(":network-caching=1500")
        media.addOption(":http-reconnect")
        if !item.isLive && resumeMs > 5000 {
            media.addOption(":start-time=\(resumeMs / 1000)")
        }

        let videoView = VLCVideoView(frame: view.bounds)
        videoView.autoresizingMask = [.width, .height]
        videoView.backColor = NSColor.black
        videoView.fillScreen = false
        view.addSubview(videoView)

        let player = VLCMediaPlayer()
        player.setVideoView(videoView)
        player.media = media

        session = Session(player: player, media: media, videoView: videoView)
        let now = PlayerEngine.clock()
        detector = StallDetector(now: now)
        startedAt = now
        audioApplied = false
        applyAudio()
        player.play()
    }

    private func detachSession() -> Session? {
        guard let s = session else { return nil }
        session = nil
        s.videoView.isHidden = true
        return s
    }

    /// Stopping can block while a broken connection times out, so it never
    /// happens on the main thread.
    private static func dispose(_ s: Session, then done: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            s.player.stop()
            DispatchQueue.main.async {
                s.videoView.removeFromSuperview()
                done?()
            }
        }
    }

    private func rememberPosition(_ s: Session) {
        guard let item = item, !item.isLive else { return }
        let time: VLCTime? = s.player.time
        let ms = Int(time?.intValue ?? 0)
        if ms > 0 { resumeMs = ms }
    }

    // MARK: - Keeping it alive

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard wantPlaying, !sleeping, let s = session, let item = item else { return }
        if userPaused {
            status = .paused
            return
        }
        let now = PlayerEngine.clock()
        let state = s.player.state
        let time: VLCTime? = s.player.time
        let ms = Int(time?.intValue ?? 0)
        // Just after a jump the player still reports the old place for a
        // moment; believing it would undo the jump in our own count.
        if ms > 0 && !item.isLive && PlayerEngine.clock() - seekedAt > 1.0 {
            resumeMs = ms
            let length: VLCTime? = s.media.length
            let total = Int(length?.intValue ?? 0)
            if total > 0 { knownLengthMs = total }
        }

        let pictures = Int(s.media.numberOfDisplayedPictures)
        let signature = [ms, Int(s.media.numberOfReadBytesOnInput), pictures]
        // "Playing" means something has reached the screen or the speakers,
        // not merely that the connection opened.
        let showing = s.player.isPlaying && (pictures > 0 || ms > 0)
        let idle = detector.observe(signature: signature, playing: showing, now: now)

        switch state {
        case .error:
            retry()
            return
        case .ended:
            if item.isLive || endedEarly(s) {
                retry()
            } else {
                finish()
            }
            return
        case .stopped:
            if now - startedAt > 3 {
                retry()
                return
            }
        default:
            break
        }

        var limit = detector.limit(openingAllowance: 15)
        if now < suspectUntil { limit = min(limit, detector.hasPlayed ? 4 : 10) }
        if idle > limit {
            retry()
            return
        }

        if detector.hasPlayed && idle < 1.5 {
            if !audioApplied {
                audioApplied = true
                applyAudio()
            }
            everPlayed = true
            recordIfPlaying()
            if now - startedAt > 10 { attempt = 0 }
            status = .playing
        } else if attempt > 0 {
            status = .reconnecting(attempt: attempt)
        } else if !detector.hasPlayed {
            status = .opening
        }
    }

    /// A film whose connection dropped also reports "ended". It only really
    /// ended if it got close to its full length.
    private func endedEarly(_ s: Session) -> Bool {
        let length: VLCTime? = s.media.length
        let total = Int(length?.intValue ?? 0)
        guard total > 60_000 else { return false }
        return resumeMs < total - 30_000
    }

    private func retry() {
        guard retryWork == nil else { return }
        attempt += 1
        if let s = detachSession() { PlayerEngine.dispose(s) }
        // Never knock on the provider's door forever: an account that is
        // over its limit or blocked is only made worse by more attempts.
        if !everPlayed && attempt > 4 {
            fail("This channel isn't responding.")
            return
        }
        if attempt > 8 {
            fail("The connection was lost.")
            return
        }
        status = .reconnecting(attempt: attempt)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.retryWork = nil
            if self.wantPlaying && !self.sleeping && !self.userPaused {
                self.open()
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Backoff.delay(forAttempt: attempt),
                                      execute: work)
    }

    private func cancelRetry() {
        retryWork?.cancel()
        retryWork = nil
    }

    private func finish() {
        cancelRetry()
        wantPlaying = false
        endRecording()
        generation += 1
        if let s = detachSession() { PlayerEngine.dispose(s) }
        stopTimer()
        status = .ended
    }

    private func fail(_ message: String) {
        cancelRetry()
        wantPlaying = false
        endRecording()
        generation += 1
        if let s = detachSession() { PlayerEngine.dispose(s) }
        stopTimer()
        status = .failed(message)
    }

    private func applyAudio() {
        guard let s = session else { return }
        let audio: VLCAudio? = s.player.audio
        audio?.volume = Int32(volume)
        audio?.isMuted = muted
    }

    // MARK: - Addresses

    /// Playlists sometimes append player hints after a `|`, and sometimes
    /// carry characters a strict address may not contain.
    static func streamURL(from text: String) -> URL? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bar = address.firstIndex(of: "|") {
            address = String(address[address.startIndex..<bar])
        }
        if address.isEmpty { return nil }
        if let url = URL(string: address), url.scheme != nil { return url }
        if let escaped = address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: escaped), url.scheme != nil {
            return url
        }
        return nil
    }
}
