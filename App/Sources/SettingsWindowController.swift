import AppKit

/// TuberView's own Settings window, opened with ⌘, or from the app menu.
final class SettingsWindowController: NSWindowController {

    private let sourceField = NSTextField()
    private let guideField = NSTextField()
    private let chartField = NSTextField()
    private let streamsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shiftPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recordingsLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save and Refresh", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "TuberView Settings"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: Library.didChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is built in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func present() {
        let config = ConfigStore.shared.config
        sourceField.stringValue = config.source
        guideField.stringValue = config.guideURL
        chartField.stringValue = config.tmdbKey
        streamsPopup.selectItem(withTag: min(4, max(1, config.maxStreams)))
        shiftPopup.selectItem(withTag: GuideStore.shared.shiftHours)
        showRecordingsFolder()
        libraryChanged()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func build() {
        guard let content = window?.contentView else { return }

        sourceField.placeholderString = "https://…  or the path to an .m3u file"
        sourceField.lineBreakMode = .byTruncatingMiddle
        sourceField.usesSingleLineMode = true
        sourceField.cell?.isScrollable = true
        guideField.placeholderString = "https://…/epg.xml"
        guideField.lineBreakMode = .byTruncatingMiddle
        guideField.usesSingleLineMode = true
        guideField.cell?.isScrollable = true

        chartField.placeholderString = "Your TMDB API key"
        chartField.lineBreakMode = .byTruncatingMiddle
        chartField.usesSingleLineMode = true
        chartField.cell?.isScrollable = true
        let chartNote = note("Movies and Series open with a Top 10 row. With a free key from themoviedb.org (Settings, then API), the row follows this week's most popular films and shows, checked once a day. Without one it goes by your provider's ratings. Nothing about your library is sent.")

        let choose = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile))
        choose.bezelStyle = .rounded
        choose.setContentHuggingPriority(.required, for: .horizontal)

        let sourceRow = NSStackView(views: [sourceField, choose])
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 8

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomRow = NSStackView(views: [statusLabel, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12

        let sourceNote = note("The M3U link from your provider. TuberView downloads a fresh channel list when it opens if its saved copy is more than six hours old, and whenever you choose Refresh Channels. The link is kept only on this Mac.")
        let guideNote = note("The EPG link from your provider. It fills in what is on now and next, and is downloaded again about twice a day.")

        for hours in -12...12 {
            let title: String
            if hours == 0 {
                title = "As the guide gives them"
            } else if hours < 0 {
                title = hours == -1 ? "1 hour earlier" : "\(-hours) hours earlier"
            } else {
                title = hours == 1 ? "1 hour later" : "\(hours) hours later"
            }
            shiftPopup.addItem(withTitle: title)
            shiftPopup.lastItem?.tag = hours
        }
        shiftPopup.target = self
        shiftPopup.action = #selector(shiftChanged)
        let shiftRow = NSStackView(views: [
            NSTextField(labelWithString: "Show times:"), shiftPopup,
        ])
        shiftRow.orientation = .horizontal
        shiftRow.spacing = 8
        let shiftNote = note("Some guides publish their times wrongly. If programmes show at the wrong hour, move them here.")

        for n in 1...4 {
            streamsPopup.addItem(withTitle: n == 1 ? "1 channel" : "\(n) channels")
            streamsPopup.lastItem?.tag = n
        }
        streamsPopup.target = self
        streamsPopup.action = #selector(streamsChanged)
        let streamsRow = NSStackView(views: [
            NSTextField(labelWithString: "Watch at the same time, at most:"), streamsPopup,
        ])
        streamsRow.orientation = .horizontal
        streamsRow.spacing = 8
        let streamsNote = note("Set this to the number of connections your plan allows. TuberView never opens more than this, because going over can get an account locked.")

        recordingsLabel.lineBreakMode = .byTruncatingMiddle
        recordingsLabel.textColor = .secondaryLabelColor
        recordingsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recordingsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let chooseFolder = NSButton(title: "Choose Folder…", target: self,
                                    action: #selector(chooseRecordingsFolder))
        chooseFolder.bezelStyle = .rounded
        chooseFolder.setContentHuggingPriority(.required, for: .horizontal)
        let recordingsRow = NSStackView(views: [recordingsLabel, chooseFolder])
        recordingsRow.orientation = .horizontal
        recordingsRow.spacing = 8

        for label in [sourceNote, guideNote, shiftNote, streamsNote, chartNote] {
            label.preferredMaxLayoutWidth = 560
        }

        let stack = NSStackView(views: [
            heading("Playlist"),
            sourceRow,
            sourceNote,
            heading("Guide"),
            guideField,
            guideNote,
            shiftRow,
            shiftNote,
            heading("Multi-view"),
            streamsRow,
            streamsNote,
            heading("Top 10"),
            chartField,
            chartNote,
            heading("Recordings"),
            recordingsRow,
            bottomRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: sourceNote)
        stack.setCustomSpacing(18, after: shiftNote)
        stack.setCustomSpacing(18, after: streamsNote)
        stack.setCustomSpacing(18, after: chartNote)
        stack.setCustomSpacing(20, after: recordingsRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 560),
            sourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            guideField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chartNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            guideNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            streamsNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shiftNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recordingsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a playlist file (.m3u)"
        if panel.runModal() == .OK, let url = panel.url {
            sourceField.stringValue = url.path
        }
    }

    @objc private func shiftChanged() {
        let hours = shiftPopup.selectedTag()
        ConfigStore.shared.update { $0.guideShiftHours = hours }
        ConfigStore.shared.flush()
        GuideStore.shared.shiftChanged()
    }

    @objc private func streamsChanged() {
        let n = min(4, max(1, streamsPopup.selectedTag()))
        ConfigStore.shared.update { $0.maxStreams = n }
        ConfigStore.shared.flush()
    }

    private func showRecordingsFolder() {
        recordingsLabel.stringValue =
            (Recordings.location.path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Recordings.folder
        panel.message = "Choose where recordings are saved"
        if panel.runModal() == .OK, let url = panel.url {
            ConfigStore.shared.update { $0.recordingsFolder = url.path }
            ConfigStore.shared.flush()
            showRecordingsFolder()
        }
    }

    @objc private func save() {
        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let guide = guideField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceChanged = source != ConfigStore.shared.config.source
        let guideChanged = guide != ConfigStore.shared.config.guideURL
        let chartKey = chartField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chartChanged = chartKey != ConfigStore.shared.config.tmdbKey
        ConfigStore.shared.update {
            $0.source = source
            $0.guideURL = guide
            $0.tmdbKey = chartKey
            if sourceChanged { $0.lastRefresh = 0 }
        }
        ConfigStore.shared.flush()
        if sourceChanged {
            // A different playlist: the old list must not linger.
            Library.shared.clear()
        }
        Library.shared.refresh()
        if guideChanged {
            // a different guide: back to working the time shift out afresh
            ConfigStore.shared.update { $0.guideShiftHours = nil }
            shiftPopup.selectItem(withTag: GuideStore.shared.shiftHours)
            GuideStore.shared.clear()
            GuideStore.shared.refresh()
        }
        if chartChanged { PopularStore.shared.keyChanged() }
        libraryChanged()
    }

    @objc private func libraryChanged() {
        let library = Library.shared
        saveButton.isEnabled = !library.isRefreshing
        if library.isRefreshing {
            statusLabel.stringValue = "Downloading the channel list…"
            statusLabel.textColor = .secondaryLabelColor
        } else if let error = library.lastError {
            statusLabel.stringValue = error
            statusLabel.textColor = .systemOrange
        } else if !library.channels.isEmpty {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let n = formatter.string(from: NSNumber(value: library.channels.count))
                ?? String(library.channels.count)
            statusLabel.stringValue = "\(n) entries loaded."
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = ""
        }
    }
}
