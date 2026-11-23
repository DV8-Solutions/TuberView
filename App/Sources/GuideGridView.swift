import AppKit
import TuberCore

/// How the guide lays time out. Shared by the header and every row so
/// they line up.
struct GuideSpan {
    /// Width of the channel column, including the gap after it.
    static let channelWidth: CGFloat = 264
    static let rowHeight: CGFloat = 63
    static let blockHeight: CGFloat = 56
    /// How much time the grid shows across its width.
    static let minutes: Double = 150

    var start: TimeInterval
    var now: TimeInterval

    var end: TimeInterval { start + GuideSpan.minutes * 60 }

    func x(_ time: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((time - start) / (GuideSpan.minutes * 60)) * width
    }

    /// The half hour that contains `now`, moved by `slots` half hours.
    static func starting(now: TimeInterval, slots: Int) -> GuideSpan {
        let base = (now / 1800).rounded(.down) * 1800
        return GuideSpan(start: base + Double(slots) * 1800, now: now)
    }
}

/// The shows of one channel as rounded blocks along the time line.
final class ProgrammeStrip: NSView {
    var span = GuideSpan(start: 0, now: 0)
    var shows: [Programme] = []
    var emptyText = "No guide information"

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("ProgrammeStrip is built in code")
    }

    func set(span: GuideSpan, shows: [Programme], emptyText: String) {
        self.span = span
        self.shows = shows
        self.emptyText = emptyText
        needsDisplay = true
    }

    private static let titleFont = Theme.rounded(13.5, .semibold)
    private static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width
        guard width > 40 else { return }
        let top = (bounds.height - GuideSpan.blockHeight) / 2
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail

        if shows.isEmpty {
            let rect = NSRect(x: 2, y: top, width: width - 4, height: GuideSpan.blockHeight)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: rect.height / 2, yRadius: rect.height / 2)
            Theme.card.withAlphaComponent(0.55).setFill()
            path.fill()
            Theme.cardLine.setStroke()
            path.stroke()
            let text = NSAttributedString(string: emptyText, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.muted,
                .paragraphStyle: style,
            ])
            text.draw(in: NSRect(x: rect.minX + 20, y: rect.midY - 8, width: rect.width - 40, height: 18))
        }

        for show in shows {
            let x0 = max(0, span.x(show.start, width: width))
            let x1 = min(width, span.x(show.stop, width: width))
            guard x1 - x0 > 6 else { continue }
            let rect = NSRect(x: x0 + 2, y: top, width: x1 - x0 - 4, height: GuideSpan.blockHeight)
            let radius = min(rect.height, rect.width) / 2
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            let on = show.start <= span.now && span.now < show.stop
            (on ? Theme.gold : Theme.card).setFill()
            path.fill()
            if !on {
                Theme.cardLine.setStroke()
                path.stroke()
            }
        }

        // the present moment, as one line down the whole grid
        let nowX = span.x(span.now, width: width)
        if nowX >= 0 && nowX <= width {
            NSColor.white.setFill()
            NSRect(x: nowX - 1, y: 0, width: 2, height: bounds.height).fill()
        }

        for show in shows {
            let x0 = max(0, span.x(show.start, width: width))
            let x1 = min(width, span.x(show.stop, width: width))
            guard x1 - x0 > 6 else { continue }
            let rect = NSRect(x: x0 + 2, y: top, width: x1 - x0 - 4, height: GuideSpan.blockHeight)
            let on = show.start <= span.now && span.now < show.stop
            guard rect.width > 64 else { continue }
            let inset: CGFloat = min(18, rect.width * 0.18)
            let area = NSRect(x: rect.minX + inset, y: rect.minY, width: rect.width - inset * 2, height: rect.height)
            let title = NSAttributedString(string: show.title, attributes: [
                .font: ProgrammeStrip.titleFont,
                .foregroundColor: on ? Theme.onGold : Theme.text,
                .paragraphStyle: style,
            ])
            title.draw(in: NSRect(x: area.minX, y: area.minY + 10, width: area.width, height: 18))
            let times = "\(Theme.time(show.start)) – \(Theme.time(show.stop))"
            let line = NSAttributedString(string: times, attributes: [
                .font: ProgrammeStrip.timeFont,
                .foregroundColor: on ? Theme.onGoldSoft : Theme.muted,
                .paragraphStyle: style,
            ])
            line.draw(in: NSRect(x: area.minX, y: area.minY + 30, width: area.width, height: 16))
        }

    }
}

/// The clock above the grid, with the buttons that move through time.
final class GuideHeader: NSView {
    var span = GuideSpan(start: 0, now: 0) {
        didSet { needsDisplay = true }
    }
    var onMove: ((Int) -> Void)?
    var onNow: (() -> Void)?

    private let earlier = IconButton(symbol: "chevron.left", tip: "Earlier", size: 12, target: nil, action: nil)
    private let later = IconButton(symbol: "chevron.right", tip: "Later", size: 12, target: nil, action: nil)
    private let dayLabel = Theme.label(font: NSFont.systemFont(ofSize: 12, weight: .semibold), color: Theme.soft)

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        earlier.target = self
        earlier.action = #selector(earlierPressed)
        later.target = self
        later.action = #selector(laterPressed)
        let click = NSClickGestureRecognizer(target: self, action: #selector(nowPressed))
        dayLabel.addGestureRecognizer(click)
        dayLabel.toolTip = "Back to now"
        dayLabel.alignment = .center
        addSubview(earlier)
        addSubview(later)
        addSubview(dayLabel)
        NSLayoutConstraint.activate([
            earlier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            earlier.centerYAnchor.constraint(equalTo: centerYAnchor),
            later.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GuideSpan.channelWidth - 46),
            later.centerYAnchor.constraint(equalTo: centerYAnchor),
            dayLabel.leadingAnchor.constraint(equalTo: earlier.trailingAnchor, constant: 2),
            dayLabel.trailingAnchor.constraint(equalTo: later.leadingAnchor, constant: -2),
            dayLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("GuideHeader is built in code")
    }

    @objc private func earlierPressed() { onMove?(-1) }
    @objc private func laterPressed() { onMove?(1) }
    @objc private func nowPressed() { onNow?() }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    func setDay() {
        let date = Date(timeIntervalSince1970: span.start)
        let calendar = Calendar.current
        let showsNow = span.now >= span.start && span.now < span.end
        if showsNow {
            dayLabel.stringValue = "Now"
            dayLabel.textColor = Theme.soft
        } else {
            let name = calendar.isDateInToday(date) ? "Today"
                : calendar.isDateInTomorrow(date) ? "Tomorrow"
                : calendar.isDateInYesterday(date) ? "Yesterday"
                : GuideHeader.day.string(from: date)
            dayLabel.stringValue = "\(name) · Back to now"
            dayLabel.textColor = Theme.gold
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let left = GuideSpan.channelWidth
        let width = bounds.width - left
        guard width > 40 else { return }
        var tick = span.start
        while tick < span.end {
            let x = left + span.x(tick, width: width)
            Theme.line.setFill()
            NSRect(x: x, y: 4, width: 1, height: bounds.height - 4).fill()
            let text = NSAttributedString(string: Theme.time(tick), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: Theme.muted,
            ])
            text.draw(at: NSPoint(x: x + 8, y: 6))
            tick += 1800
        }
        let nowX = span.x(span.now, width: width)
        if nowX >= 0 && nowX <= width {
            let label = NSAttributedString(string: Theme.time(span.now).replacingOccurrences(of: " PM", with: "")
                .replacingOccurrences(of: " AM", with: ""), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .heavy),
                .foregroundColor: Theme.onGold,
            ])
            let size = label.size()
            var badge = NSRect(x: left + nowX - (size.width + 14) / 2, y: 4, width: size.width + 14, height: 18)
            badge.origin.x = max(left, min(bounds.width - badge.width, badge.origin.x))
            NSColor.white.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 9, yRadius: 9).fill()
            label.draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + (18 - size.height) / 2))
            NSRect(x: left + nowX - 1, y: badge.maxY, width: 2, height: bounds.height - badge.maxY).fill()
        }
    }
}

/// One channel: its rounded name plate on the left, its shows on the right.
final class GuideRow: NSTableCellView {
    private let plate = Box(color: Theme.card, radius: GuideSpan.blockHeight / 2, border: Theme.cardLine)
    private let logo = ArtView(shape: .logo)
    private let nameLabel = Theme.label(font: Theme.rounded(13.5, .semibold), color: Theme.text)
    private let star = IconButton(symbol: "star", tip: "Add to Favorites", size: 12, target: nil, action: nil)
    let strip = ProgrammeStrip()
    var onStar: (() -> Void)?
    private var starred = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        star.target = self
        star.action = #selector(starPressed)
        addSubview(plate)
        plate.addSubview(logo)
        plate.addSubview(nameLabel)
        plate.addSubview(star)
        addSubview(strip)
        NSLayoutConstraint.activate([
            plate.leadingAnchor.constraint(equalTo: leadingAnchor),
            plate.widthAnchor.constraint(equalToConstant: GuideSpan.channelWidth - 8),
            plate.centerYAnchor.constraint(equalTo: centerYAnchor),
            plate.heightAnchor.constraint(equalToConstant: GuideSpan.blockHeight),
            logo.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
            logo.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 40),
            logo.heightAnchor.constraint(equalToConstant: 40),
            nameLabel.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: star.leadingAnchor, constant: -2),
            star.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -8),
            star.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GuideSpan.channelWidth),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("GuideRow is built in code")
    }

    @objc private func starPressed() { onStar?() }

    func show(_ channel: Channel, span: GuideSpan, chosen: Bool) {
        nameLabel.stringValue = channel.name
        nameLabel.toolTip = channel.group.isEmpty ? channel.name : "\(channel.name)\n\(channel.group)"
        logo.show(address: channel.logo, name: channel.name, maxPixel: 120)
        starred = Favorites.shared.contains(channel)
        star.show(symbol: starred ? "star.fill" : "star", size: 12)
        star.contentTintColor = starred ? Theme.gold : Theme.muted.withAlphaComponent(0.6)
        star.toolTip = starred ? "Remove from Favorites" : "Add to Favorites"
        star.setAccessibilityLabel(star.toolTip)
        plate.recolor(chosen ? Theme.goldDim : Theme.card, border: chosen ? Theme.gold : Theme.cardLine)
        switch channel.kind {
        case .live:
            let shows = GuideStore.shared.programmes(guideID: channel.guideID, name: channel.name,
                                                     from: span.start, to: span.end)
            strip.set(span: span, shows: shows, emptyText: "No guide information")
        case .movie:
            strip.set(span: span, shows: [], emptyText: "Film · click to watch")
        case .episode:
            strip.set(span: span, shows: [], emptyText: "Episode · click to watch")
        }
    }
}

/// A table that plays the highlighted row on Return.
final class GuideTableView: NSTableView {
    var onReturn: (() -> Void)?
    /// Returns true when Esc was used.
    var onEscape: (() -> Bool)?
    /// A menu for the row that was right-clicked.
    var onMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return onMenu?(row)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else if event.keyCode == 53, onEscape?() == true {
            // used
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Live TV as a guide: a row for every channel, time across the top.
final class GuideGridView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onPlay: ((Channel) -> Void)?
    var onHighlight: ((Channel?) -> Void)?
    var onEscape: (() -> Bool)?

    private let header = GuideHeader()
    let table = GuideTableView()
    private let scroll = NSScrollView()
    private(set) var rows: [Channel] = []
    private var slots = 0
    private var span = GuideSpan.starting(now: Date().timeIntervalSince1970, slots: 0)
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("guide"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = GuideSpan.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.style = .plain
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        // one click on a channel opens it
        table.action = #selector(rowClicked)
        table.onReturn = { [weak self] in
            guard let self = self, let channel = self.highlighted else { return }
            self.onPlay?(channel)
        }
        table.onEscape = { [weak self] in self?.onEscape?() ?? false }
        table.setAccessibilityLabel("Channels")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        table.sizeLastColumnToFit()

        header.onMove = { [weak self] by in self?.move(by) }
        header.onNow = { [weak self] in
            guard let self = self else { return }
            self.slots = 0
            self.tick()
        }
        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            header.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    required init?(coder: NSCoder) {
        fatalError("GuideGridView is built in code")
    }

    deinit {
        timer?.invalidate()
    }

    private func move(_ by: Int) {
        slots = max(-6, min(84, slots + by))
        tick()
    }

    /// Bring the clock up to date and repaint what is on screen.
    func tick() {
        span = GuideSpan.starting(now: Date().timeIntervalSince1970, slots: slots)
        header.span = span
        header.setDay()
        redraw()
    }

    /// Repaint the rows on screen without moving anything.
    func redraw() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        let chosen = table.selectedRow
        for row in visible.location..<(visible.location + visible.length) where row < rows.count {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GuideRow else { continue }
            cell.show(rows[row], span: span, chosen: row == chosen)
        }
    }

    var highlighted: Channel? {
        let row = table.selectedRow
        return row >= 0 && row < rows.count ? rows[row] : nil
    }

    /// Replace the rows. The highlighted channel stays highlighted when it
    /// is still there; `reveal` also scrolls to it, or to the top.
    func show(_ list: [Channel], reveal: Bool) {
        let keep = highlighted
        rows = list
        table.reloadData()
        var row = -1
        if let keep = keep {
            row = list.firstIndex(where: { $0.url == keep.url && $0.index == keep.index })
                ?? list.firstIndex(where: { $0.url == keep.url }) ?? -1
        }
        if row < 0 && !list.isEmpty {
            if reveal { table.scrollRowToVisible(0) }
        } else if row >= 0 && reveal {
            table.scrollRowToVisible(row)
        }
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        redraw()
        onHighlight?(highlighted)
    }

    func select(url: String) {
        guard let row = rows.firstIndex(where: { $0.url == url }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func neighbor(of channel: Channel, offset: Int) -> Channel? {
        guard let row = rows.firstIndex(where: { $0.url == channel.url }) else { return nil }
        var candidate = row + offset
        while candidate >= 0 && candidate < rows.count {
            if rows[candidate].kind == channel.kind { return rows[candidate] }
            candidate += offset
        }
        return nil
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("GuideRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? GuideRow)
            ?? GuideRow(identifier: identifier)
        let channel = rows[row]
        cell.show(channel, span: span, chosen: row == tableView.selectedRow)
        cell.onStar = { Favorites.shared.toggle(channel) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        redraw()
        onHighlight?(highlighted)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        onPlay?(rows[row])
    }
}
