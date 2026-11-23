import AppKit
import TuberCore

/// The wide panel above a list: what is on the chosen channel, or the
/// film or episode to carry on with.
final class BannerView: NSView {
    var onAction: (() -> Void)?
    var onStar: (() -> Void)?

    private let panel = Box(color: Theme.rgb(0x2A2119), radius: 24, border: Theme.rgb(0x3A3128))
    private let art = ArtView(shape: .poster)
    private let eyebrow = Theme.label(font: NSFont.systemFont(ofSize: 10.5, weight: .bold), color: Theme.gold)
    private let title = Theme.label(font: Theme.serif(28), color: Theme.text)
    private let detail = Theme.label(font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                                     color: Theme.soft)
    private let progress = ProgressLine()
    private let action = PillButton("Watch", look: .primary, symbol: "play.fill", target: nil, action: nil)
    private let star = PillButton("Favorite", look: .outline, symbol: "star", target: nil, action: nil)
    private let gradient = CAGradientLayer()

    static let height: CGFloat = 148

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        action.target = self
        action.action = #selector(actionPressed)
        star.target = self
        star.action = #selector(starPressed)

        gradient.colors = [Theme.rgb(0x3B2A14).cgColor, Theme.rgb(0x2A2119).cgColor, Theme.rgb(0x1E1A16).cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.cornerRadius = 24
        panel.layer?.insertSublayer(gradient, at: 0)
        panel.layer?.masksToBounds = true

        let words = NSStackView(views: [eyebrow, title, detail, progress])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 5
        words.setCustomSpacing(10, after: detail)
        words.translatesAutoresizingMaskIntoConstraints = false

        addSubview(panel)
        panel.addSubview(art)
        panel.addSubview(words)
        panel.addSubview(action)
        panel.addSubview(star)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            heightAnchor.constraint(equalToConstant: BannerView.height),

            art.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            art.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            art.heightAnchor.constraint(equalToConstant: BannerView.height - 36),
            art.widthAnchor.constraint(equalToConstant: BannerView.height - 36),

            words.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 22),
            words.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            words.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -20),
            title.widthAnchor.constraint(lessThanOrEqualTo: words.widthAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualTo: words.widthAnchor),
            progress.widthAnchor.constraint(equalToConstant: 380).withPriority(.defaultHigh),
            progress.widthAnchor.constraint(lessThanOrEqualTo: words.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),

            star.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            star.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            action.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -10),
            action.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("BannerView is built in code")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = panel.bounds
        CATransaction.commit()
    }

    @objc private func actionPressed() { onAction?() }
    @objc private func starPressed() { onStar?() }

    /// A live channel and what it is showing.
    func show(channel: Channel) {
        let pair = GuideStore.shared.nowAndNext(guideID: channel.guideID, name: channel.name)
        var top = channel.kind == .live ? "ON NOW" : (channel.kind == .movie ? "FILM" : "EPISODE")
        top += " · " + channel.name.uppercased()
        if !channel.group.isEmpty { top += " · " + channel.group.uppercased() }
        eyebrow.stringValue = top
        let now = Date().timeIntervalSince1970
        if let on = pair.now {
            title.stringValue = on.title
            var line = "\(Theme.time(on.start)) – \(Theme.time(on.stop)) · \(Theme.span(on.stop - now)) left"
            if let next = pair.next { line += " · Next: \(next.title)" }
            detail.stringValue = line
            progress.fraction = CGFloat((now - on.start) / max(1, on.stop - on.start))
            progress.isHidden = false
        } else {
            title.stringValue = channel.name
            if let next = pair.next {
                detail.stringValue = "Next: \(Theme.time(next.start)) \(next.title)"
            } else {
                detail.stringValue = channel.kind == .live ? "No guide information for this channel" : ""
            }
            progress.isHidden = true
        }
        art.fitsInside = channel.kind == .live
        art.show(address: channel.logo, name: channel.kind == .live ? Theme.mark(for: channel.name) : channel.name,
                 maxPixel: 300)
        action.rename("Watch")
        let starred = Favorites.shared.contains(channel)
        star.rename(starred ? "Favorited" : "Favorite")
        star.image = Theme.symbol(starred ? "star.fill" : "star", "Favorite", size: 11, weight: .bold)
        star.isHidden = false
    }

    /// A film or an episode that was left part way through.
    func show(resume title: String, detail: String, poster: String, fraction: CGFloat) {
        eyebrow.stringValue = "CONTINUE WATCHING"
        self.title.stringValue = title
        self.detail.stringValue = detail
        progress.fraction = fraction
        progress.isHidden = false
        art.fitsInside = false
        art.show(address: poster, name: title, maxPixel: 300)
        action.rename("Resume")
        star.isHidden = true
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

/// A plain dark row for the episode and recording lists.
final class LineCell: NSTableCellView {
    private let box = Box(color: Theme.card, radius: 22, border: Theme.cardLine)
    private let titleLabel = Theme.label(font: Theme.rounded(13.5, .semibold), color: Theme.text)
    private let detailLabel = Theme.label(font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                                          color: Theme.muted)
    private let icon = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.image = Theme.symbol("play.fill", "Play", size: 11, weight: .bold)
        icon.contentTintColor = Theme.gold
        icon.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(box)
        box.addSubview(icon)
        box.addSubview(titleLabel)
        box.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12),
            detailLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            detailLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("LineCell is built in code")
    }

    func show(title: String, detail: String, chosen: Bool) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        box.recolor(chosen ? Theme.goldDim : Theme.card, border: chosen ? Theme.gold : Theme.cardLine)
    }
}

/// One show: its poster, its seasons, and the episodes of the season
/// chosen.
final class ShowDetailView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlay: ((Channel) -> Void)?
    var onBack: (() -> Void)?

    private let back = PillButton("Series", look: .outline, symbol: "chevron.left", target: nil, action: nil)
    private let art = ArtView(shape: .poster)
    private let title = Theme.label(font: Theme.serif(30), color: Theme.text)
    private let facts = Theme.label(font: NSFont.systemFont(ofSize: 13), color: Theme.soft)
    private let seasonRow = NSStackView()
    private let seasonScroll = NSScrollView()
    private let table = GuideTableView()
    private let scroll = NSScrollView()

    private var show: ShowItem?
    private var season = 0
    /// One row for each episode; a row holds every copy the provider
    /// lists of it, since each copy is its own entry in the playlist.
    private var episodes: [[EpisodeRef]] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        back.target = self
        back.action = #selector(backPressed)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.wraps = true
        title.cell?.truncatesLastVisibleLine = true

        seasonRow.orientation = .horizontal
        seasonRow.spacing = 8
        seasonRow.translatesAutoresizingMaskIntoConstraints = false
        seasonScroll.documentView = seasonRow
        seasonScroll.drawsBackground = false
        seasonScroll.hasHorizontalScroller = false
        seasonScroll.hasVerticalScroller = false
        seasonScroll.automaticallyAdjustsContentInsets = false
        seasonScroll.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("episode"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.onReturn = { [weak self] in self?.play(row: self?.table.selectedRow ?? -1) }
        table.onEscape = { [weak self] in
            self?.onBack?()
            return true
        }
        table.onMenu = { [weak self] row in self?.versions(row: row) }
        table.setAccessibilityLabel("Episodes")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.sizeLastColumnToFit()

        addSubview(back)
        addSubview(art)
        addSubview(title)
        addSubview(facts)
        addSubview(seasonScroll)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

            art.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 16),
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            art.widthAnchor.constraint(equalToConstant: 200),
            art.heightAnchor.constraint(equalToConstant: 300),

            title.topAnchor.constraint(equalTo: art.topAnchor),
            title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 28),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),
            facts.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            facts.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            facts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -40),

            seasonScroll.topAnchor.constraint(equalTo: facts.bottomAnchor, constant: 14),
            seasonScroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            seasonScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            seasonScroll.heightAnchor.constraint(equalToConstant: 32),
            seasonRow.leadingAnchor.constraint(equalTo: seasonScroll.contentView.leadingAnchor),
            seasonRow.topAnchor.constraint(equalTo: seasonScroll.contentView.topAnchor),
            seasonRow.bottomAnchor.constraint(equalTo: seasonScroll.contentView.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: seasonScroll.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("ShowDetailView is built in code")
    }

    @objc private func backPressed() { onBack?() }

    var list: NSView { table }

    func open(_ show: ShowItem) {
        self.show = show
        title.stringValue = show.name
        art.show(address: show.poster, name: show.name, maxPixel: 600)
        var parts: [String] = []
        if let rating = RatingsStore.text(RatingsStore.shared.show(name: show.name)) {
            parts.append("★ \(rating)")
        }
        if !show.genres.isEmpty {
            parts.append(show.genres.filter { !$0.lowercased().contains("latest") }.prefix(4).joined(separator: " · "))
        }
        let seasons = show.seasons
        parts.append(seasons.count == 1 ? "1 season" : "\(seasons.count) seasons")
        var distinct = 0
        var last: (Int, Int)?
        for e in show.episodes where last == nil || last! != (e.season, e.episode) {
            distinct += 1
            last = (e.season, e.episode)
        }
        parts.append(distinct == 1 ? "1 episode" : "\(distinct) episodes")
        facts.stringValue = parts.filter { !$0.isEmpty }.joined(separator: "   ")

        // open on the season that was being watched, else the first
        var wanted = seasons.first ?? 0
        let channels = CatalogStore.shared
        for entry in Recents.shared.entries {
            if let hit = show.episodes.first(where: { channels.channel(at: $0.channel)?.url == entry.url }) {
                wanted = hit.season
                break
            }
        }
        for view in seasonRow.arrangedSubviews {
            seasonRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for number in seasons {
            let chip = PillButton(number == 0 ? "Episodes" : "Season \(number)", look: .chip,
                                  target: self, action: #selector(seasonPressed(_:)))
            chip.tag = number
            seasonRow.addArrangedSubview(chip)
        }
        choose(season: wanted)
    }

    @objc private func seasonPressed(_ sender: NSButton) {
        choose(season: sender.tag)
    }

    private func choose(season number: Int) {
        season = number
        for case let chip as PillButton in seasonRow.arrangedSubviews {
            chip.isOn = chip.tag == number
        }
        episodes = []
        for e in (show?.episodes ?? []) where e.season == number {
            if let last = episodes.last?.first, last.episode == e.episode {
                episodes[episodes.count - 1].append(e)
            } else {
                episodes.append([e])
            }
        }
        table.reloadData()
        if !episodes.isEmpty { table.scrollRowToVisible(0) }
    }

    /// The episode before or after this one, across seasons.
    static func neighbor(of url: String, in show: ShowItem, offset: Int) -> Channel? {
        let store = CatalogStore.shared
        guard let at = show.episodes.firstIndex(where: { store.channel(at: $0.channel)?.url == url }) else {
            return nil
        }
        // step past the other copies of the same episode
        let here = show.episodes[at]
        var next = at + offset
        while next >= 0, next < show.episodes.count,
              show.episodes[next].season == here.season, show.episodes[next].episode == here.episode {
            next += offset
        }
        guard offset != 0, next >= 0, next < show.episodes.count else { return nil }
        return store.channel(at: show.episodes[next].channel)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { episodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < episodes.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("EpisodeCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? LineCell)
            ?? LineCell(identifier: identifier)
        let copies = episodes[row]
        let episode = copies[0]
        var notes: [String] = []
        if let channel = preferred(row: row) {
            let at = ResumePoints.shared.position(for: channel.url)
            if at > 0 { notes.append("\(Theme.span(Double(at) / 1000)) in") }
        }
        if copies.count > 1 { notes.append("\(copies.count) versions, right-click to choose") }
        let detail = notes.joined(separator: " · ")
        let name = "Episode \(episode.episode)"
        cell.show(title: name, detail: detail, chosen: row == tableView.selectedRow)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<episodes.count), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func rowClicked() {
        play(row: table.clickedRow)
    }

    private func play(row: Int) {
        guard row >= 0, row < episodes.count, let channel = preferred(row: row) else { return }
        onPlay?(channel)
    }

    /// The copy of an episode to play: one that was already started,
    /// otherwise the first listed.
    private func preferred(row: Int) -> Channel? {
        let store = CatalogStore.shared
        let copies = episodes[row].compactMap { store.channel(at: $0.channel) }
        return copies.first(where: { ResumePoints.shared.position(for: $0.url) > 0 }) ?? copies.first
    }

    private func versions(row: Int) -> NSMenu? {
        guard row >= 0, row < episodes.count, episodes[row].count > 1 else { return nil }
        let menu = NSMenu()
        for (i, copy) in episodes[row].enumerated() {
            let item = NSMenuItem(title: "Play Version \(i + 1)", action: #selector(versionChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = copy.channel
            menu.addItem(item)
        }
        return menu
    }

    @objc private func versionChosen(_ sender: NSMenuItem) {
        guard let channel = CatalogStore.shared.channel(at: sender.tag) else { return }
        onPlay?(channel)
    }
}

/// The recordings folder as a list.
final class RecordingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlay: ((Channel) -> Void)?
    var onEscape: (() -> Bool)?

    struct File {
        let url: URL
        let date: Date
        let size: Int64
    }

    private let table = GuideTableView()
    private let scroll = NSScrollView()
    private let reveal = PillButton("Show in Finder", look: .outline, target: nil, action: nil)
    private let heading = Theme.label("Recordings", font: Theme.serif(26), color: Theme.text)
    private(set) var files: [File] = []

    private static let endings: Set<String> = ["ts", "mp4", "mkv", "mov", "m4v", "avi", "mpg", "mpeg", "flv", "webm"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        reveal.target = self
        reveal.action = #selector(revealPressed)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recording"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.focusRingType = .none
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.onReturn = { [weak self] in self?.play(row: self?.table.selectedRow ?? -1) }
        table.onEscape = { [weak self] in self?.onEscape?() ?? false }
        table.setAccessibilityLabel("Recordings")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.sizeLastColumnToFit()

        addSubview(heading)
        addSubview(reveal)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            reveal.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            reveal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("RecordingsView is built in code")
    }

    var list: NSView { table }

    @objc private func revealPressed() {
        NSWorkspace.shared.open(Recordings.folder)
    }

    /// Read the folder again. Only finished recordings are listed.
    func reload() {
        let fm = FileManager.default
        let folder = Recordings.location
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles])) ?? []
        var list: [File] = []
        for url in found where RecordingsView.endings.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? false else { continue }
            list.append(File(url: url, date: values?.contentModificationDate ?? .distantPast,
                             size: Int64(values?.fileSize ?? 0)))
        }
        files = list.sorted { $0.date > $1.date }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < files.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RecordingCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? LineCell)
            ?? LineCell(identifier: identifier)
        let file = files[row]
        let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        cell.show(title: file.url.deletingPathExtension().lastPathComponent,
                  detail: "\(RecordingsView.stamp.string(from: file.date)) · \(size)",
                  chosen: row == tableView.selectedRow)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<files.count), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func rowDoubleClicked() {
        play(row: table.clickedRow)
    }

    private func play(row: Int) {
        guard row >= 0, row < files.count else { return }
        let file = files[row]
        onPlay?(Channel(index: -1, name: file.url.deletingPathExtension().lastPathComponent,
                        group: "Recordings", logo: "", guideID: "",
                        url: file.url.absoluteString, kind: .movie))
    }
}
