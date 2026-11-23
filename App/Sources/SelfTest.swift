import AppKit
import TuberCore

/// A check the cloud build runs: `TuberView --selftest <address>`.
///
/// It plays the address, waits for a picture, then pretends the Mac slept
/// and woke, and waits for the picture to come back. Then it records for a
/// few seconds and checks that a file was written. It prints what happened
/// and quits with 0 only if all of it worked. It is never used in normal running.
final class SelfTest {
    private let main: MainWindowController
    private let address: String
    private var timer: Timer?
    private var phase = 0
    private var phaseStarted = Date()
    private var steadyTicks = 0

    static func requestedAddress() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    init(main: MainWindowController, address: String) {
        self.main = main
        self.address = address
    }

    func start() {
        say("opening the test stream")
        let channel = Channel(index: 0, name: "Self test", group: "", logo: "", guideID: "",
                              url: address, kind: M3U.kind(for: address))
        main.play(channel)
        phaseStarted = Date()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func say(_ text: String) {
        print("SELFTEST: \(text)")
        fflush(stdout)
    }

    private func finish(_ code: Int32, _ text: String) {
        say(text)
        timer?.invalidate()
        main.showLibrary()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(code) }
    }

    private func checkRecording() {
        let fm = FileManager.default
        let folder = Recordings.folder
        var best = 0
        var seen: [String] = []
        let names = (try? fm.subpathsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let path = folder.appendingPathComponent(name).path
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            seen.append("\(name) (\(size) bytes)")
            if !name.contains("/") && !name.hasPrefix(".") && name.hasPrefix("Self test") {
                best = max(best, size)
            }
        }
        say("recordings folder: " + (seen.isEmpty ? "empty" : seen.joined(separator: ", ")))
        if best > 100_000 {
            finish(0, "RECORDED \(best) bytes. PASS")
        } else {
            finish(5, "FAILED: no recording file was written")
        }
    }

    /// `--shots <folder>`: save what the player window looks like.
    private func takePicture() {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--shots"), at + 1 < args.count,
              let window = main.window else { return }
        let file = URL(fileURLWithPath: args[at + 1]).appendingPathComponent("player-screen.png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        if (try? task.run()) != nil {
            task.waitUntilExit()
            say("picture of the player saved")
        }
    }

    private func tick() {
        guard phase < 3 else { return }
        let status = main.player.engine.status
        let waited = Date().timeIntervalSince(phaseStarted)
        if case .failed(let why) = status {
            finish(2, "FAILED in phase \(phase): \(why)")
            return
        }
        if waited > 60 {
            finish(3, "TIMED OUT in phase \(phase), status \(status)")
            return
        }
        steadyTicks = status == .playing ? steadyTicks + 1 : 0
        // two seconds of steady playing, not one lucky reading
        guard steadyTicks >= 4 else { return }

        if phase == 0 {
            say("PLAYING after \(String(format: "%.1f", waited))s")
            // a picture of the player with its controls showing, for review
            phase = 10
            main.player.showControlsForPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.takePicture()
                self.say("pretending the Mac slept and woke")
                self.phase = 1
                self.steadyTicks = 0
                self.phaseStarted = Date()
                self.main.player.engine.prepareForSleep()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.main.player.engine.didWake()
                }
            }
        } else if phase == 1 {
            say("RECOVERED after \(String(format: "%.1f", waited))s")
            say("recording for a few seconds")
            phase = 2
            steadyTicks = 0
            phaseStarted = Date()
            if !main.player.engine.startRecording(stage: Recordings.newStage(title: "Self test")) {
                finish(4, "FAILED: recording did not start")
            }
        } else if waited >= 8 {
            phase = 3
            main.player.engine.stopRecording()
            say("recording stopped, picture still \(main.player.engine.status)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.checkRecording()
            }
        }
    }
}
