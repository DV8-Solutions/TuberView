import AppKit
import TuberCore

protocol LibraryViewControllerDelegate: AnyObject {
    func library(_ library: LibraryViewController, didChoose channel: Channel)
    func libraryDidRequestSettings(_ library: LibraryViewController)
    /// Go back to the pictures without choosing anything.
    func libraryDidCancelPick(_ library: LibraryViewController)
}

/// A number that can be read from any thread, so a search running in the
/// background can tell it has been replaced by a newer one.
final class SearchTicket {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// The pages of the library, in the order of the tabs.
enum LibraryTab: Int, CaseIterable {
    case live, movies, series, favorites, recordings

    var title: String {
        switch self {
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .favorites: return "Favorites"
        case .recordings: return "Recordings"
        }
    }

    var searchPrompt: String {
        switch self {
        case .live: return "Search channels"
        case .movies: return "Search movies"
        case .series: return "Search series"
        case .favorites: return "Search favorites"
        case .recordings: return "Search"
        }
    }
}

/// The V antenna, drawn.
final class VMark: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("VMark is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let k = bounds.width / 26
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5 * k, y: 4 * k))
        path.line(to: NSPoint(x: 13 * k, y: 17 * k))
        path.line(to: NSPoint(x: 21 * k, y: 4 * k))
        path.move(to: NSPoint(x: 8 * k, y: 22 * k))
        path.line(to: NSPoint(x: 18 * k, y: 22 * k))
        path.lineWidth = 2.4 * k
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Theme.gold.setStroke()
        path.stroke()
    }
}

/// The library: tabs across the top, a search box, genre chips, and a page
/// of posters or the Live TV guide.
///
/// What is typed in the box is the only record of the current search. The
/// page on screen is always the answer to the box, the tab and the chip as
/// they are now; a slower, older answer is thrown away instead of being
/// painted over a newer one. The view stays alive while a channel plays,
/// so coming back shows exactly what was left.
final class LibraryViewController: NSViewController, NSTextFieldDelegate {

    weak var delegate: LibraryViewControllerDelegate?

    /// Set while the pictures keep playing behind the library and a channel
    /// is being chosen for one of them.
    var pickMessage: String? {
        didSet {
            guard isViewLoaded else { return }
            pickLabel.stringValue = pickMessage ?? ""
            pickStrip.isHidden = pickMessage == nil
            pickStripHolder?.isHidden = pickMessage == nil
        }
    }

    // top bar
    private let topBar = Box(color: Theme.bar)
    private let topLine = Box(color: Theme.line)
    private let wordmark = Theme.label("TuberView", font: Theme.serif(18), color: Theme.text)
    private var tabButtons: [PillButton] = []
    private let searchBox = Box(color: Theme.field, radius: 17, border: Theme.fieldLine)
    private let searchField = NSTextField()
    private lazy var clearButton = IconButton(symbol: "xmark.circle.fill", tip: "Clear search", size: 14,
                                              target: self, action: #selector(clearPressed))
    private lazy var refreshButton = IconButton(symbol: "arrow.clockwise", tip: "Refresh Channels (⌘R)",
                                                target: self, action: #selector(refreshPressed))
    private lazy var settingsButton = IconButton(symbol: "gearshape", tip: "Settings (⌘,)",
                                                 target: self, action: #selector(settingsPressed))

    // under the bar
    private let pickStrip = Box(color: Theme.goldDim, radius: 20, border: Theme.gold)
    private let pickLabel = Theme.label(font: NSFont.systemFont(ofSize: 13, weight: .semibold), color: Theme.gold)
    private let banner = BannerView()
    private let chipsRow = NSView()
    private let chipScroll = NSScrollView()
    private let chipStack = NSStackView()
    private lazy var browseButton = PillButton("All genres", look: .chip, symbol: "chevron.down",
                                               target: self, action: #selector(browsePressed))
    private var chipNames: [String?] = []

    // pages
    private let content = NSView()
    private let guide = GuideGridView()
    private let posters = PosterGridView()
    private let detail = ShowDetailView()
    private let recordings = RecordingsView()
    private let emptyLabel = Theme.label(font: NSFont.systemFont(ofSize: 16, weight: .medium), color: Theme.muted)
    private lazy var emptyButton = PillButton("Open Settings…", look: .outline,
                                              target: self, action: #selector(settingsPressed))
    private let emptyStack = NSStackView()
    private let statusLabel = Theme.label(font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                          color: Theme.muted)

    // what is on show
    private(set) var tab = LibraryTab.live
    private var genre: [LibraryTab: String] = [:]
    private var groups: [GroupCount] = []
    private var movieHits: [Int] = []
    private var showHits: [Int] = []
    /// The show whose episodes are open, by its folded name.
    private var openShow: String?
    private var shownQuestion = ""
    private var hasAnswer = false
    private var resultCount = 0
    private var bannerChannel: Channel?
    private var shownLibraryRevision = -1
    private var shownCatalogRevision = -2

    private let ticket = SearchTicket()
    private let searchQueue = DispatchQueue(label: "tuberview.search", qos: .userInitiated)
    private var statusTimer: Timer?

    private static let numbers: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    deinit {
        statusTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.ground.cgColor
        view = root

        buildTopBar(in: root)

        // choosing a channel for a second picture
        let backButton = PillButton("Back to Watching", look: .chip, target: self, action: #selector(backPressed))
        pickStrip.addSubview(pickLabel)
        pickStrip.addSubview(backButton)
        pickStrip.isHidden = true
        let pickHolder = NSView()
        pickHolder.translatesAutoresizingMaskIntoConstraints = false
        pickHolder.addSubview(pickStrip)

        // genre chips
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        chipStack.orientation = .horizontal
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.documentView = chipStack
        chipScroll.drawsBackground = false
        chipScroll.hasHorizontalScroller = false
        chipScroll.hasVerticalScroller = false
        chipScroll.automaticallyAdjustsContentInsets = false
        chipScroll.horizontalScrollElasticity = .allowed
        chipScroll.verticalScrollElasticity = .none
        chipScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsRow.addSubview(chipScroll)
        chipsRow.addSubview(browseButton)

        // pages
        content.translatesAutoresizingMaskIntoConstraints = false
        for page in [guide, posters, detail, recordings] as [NSView] {
            content.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 4
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.cell?.wraps = true
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 16
        emptyStack.addArrangedSubview(emptyLabel)
        emptyStack.addArrangedSubview(emptyButton)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyStack)

        let body = NSStackView(views: [pickHolder, banner, chipsRow, content])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addSubview(body)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            pickHolder.widthAnchor.constraint(equalTo: body.widthAnchor),
            pickHolder.heightAnchor.constraint(equalToConstant: 40),
            pickStrip.topAnchor.constraint(equalTo: pickHolder.topAnchor),
            pickStrip.bottomAnchor.constraint(equalTo: pickHolder.bottomAnchor),
            pickStrip.leadingAnchor.constraint(equalTo: pickHolder.leadingAnchor, constant: 40),
            pickStrip.trailingAnchor.constraint(equalTo: pickHolder.trailingAnchor, constant: -40),
            pickLabel.leadingAnchor.constraint(equalTo: pickStrip.leadingAnchor, constant: 18),
            pickLabel.centerYAnchor.constraint(equalTo: pickStrip.centerYAnchor),
            pickLabel.trailingAnchor.constraint(lessThanOrEqualTo: backButton.leadingAnchor, constant: -12),
            backButton.trailingAnchor.constraint(equalTo: pickStrip.trailingAnchor, constant: -6),
            backButton.centerYAnchor.constraint(equalTo: pickStrip.centerYAnchor),

            banner.widthAnchor.constraint(equalTo: body.widthAnchor),

            chipsRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            chipsRow.heightAnchor.constraint(equalToConstant: 32),
            chipScroll.leadingAnchor.constraint(equalTo: chipsRow.leadingAnchor, constant: 40),
            chipScroll.topAnchor.constraint(equalTo: chipsRow.topAnchor),
            chipScroll.bottomAnchor.constraint(equalTo: chipsRow.bottomAnchor),
            chipScroll.trailingAnchor.constraint(equalTo: browseButton.leadingAnchor, constant: -12),
            browseButton.trailingAnchor.constraint(equalTo: chipsRow.trailingAnchor, constant: -40),
            browseButton.centerYAnchor.constraint(equalTo: chipsRow.centerYAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentView.leadingAnchor),
            chipStack.topAnchor.constraint(equalTo: chipScroll.contentView.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentView.bottomAnchor),

            content.widthAnchor.constraint(equalTo: body.widthAnchor),

            emptyStack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.7),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -40),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        // the holder takes no room while nothing is being chosen
        pickHolder.isHidden = true
        pickStripHolder = pickHolder

        wire()
        showPage()
        libraryChanged()
    }

    private weak var pickStripHolder: NSView?

    private func buildTopBar(in root: NSView) {
        root.addSubview(topBar)
        root.addSubview(topLine)

        let brand = NSStackView(views: [VMark(), wordmark])
        brand.orientation = .horizontal
        brand.spacing = 8
        brand.translatesAutoresizingMaskIntoConstraints = false
        brand.setContentHuggingPriority(.required, for: .horizontal)
        wordmark.setContentCompressionResistancePriority(.required, for: .horizontal)

        for page in LibraryTab.allCases {
            let button = PillButton(page.title, look: .tab, target: self, action: #selector(tabPressed(_:)))
            button.tag = page.rawValue
            tabButtons.append(button)
        }
        let tabs = NSStackView(views: tabButtons)
        tabs.orientation = .horizontal
        tabs.spacing = 2
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.setAccessibilityLabel("Library")

        let glass = NSImageView()
        glass.image = Theme.symbol("magnifyingglass", "Search", size: 12)
        glass.contentTintColor = Theme.muted
        glass.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 13.5)
        searchField.textColor = Theme.text
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // the box keeps its width whatever is typed in it
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        searchField.setAccessibilityLabel("Search")
        searchBox.addSubview(glass)
        searchBox.addSubview(searchField)
        clearButton.contentTintColor = Theme.muted
        clearButton.isHidden = true
        searchBox.addSubview(clearButton)

        topBar.addSubview(brand)
        topBar.addSubview(tabs)
        topBar.addSubview(searchBox)
        topBar.addSubview(refreshButton)
        topBar.addSubview(settingsButton)

        let centred = tabs.centerXAnchor.constraint(equalTo: topBar.centerXAnchor)
        centred.priority = .defaultLow
        let wide = searchBox.widthAnchor.constraint(equalToConstant: 240)
        wide.priority = NSLayoutConstraint.Priority(240)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 54),
            topLine.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),

            // beside the window's three buttons
            brand.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 88),
            brand.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            centred,
            tabs.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tabs.leadingAnchor.constraint(greaterThanOrEqualTo: brand.trailingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: searchBox.leadingAnchor, constant: -14),

            settingsButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            settingsButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -2),
            refreshButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            searchBox.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            searchBox.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchBox.heightAnchor.constraint(equalToConstant: 34),
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            wide,
            glass.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 12),
            glass.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -2),
            clearButton.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -3),
            clearButton.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])
    }

    private func wire() {
        guide.onPlay = { [weak self] channel in self?.choose(channel) }
        guide.onHighlight = { [weak self] _ in self?.updateBanner() }
        guide.onEscape = { [weak self] in self?.escape() ?? false }
        posters.onOpen = { [weak self] index in self?.openTile(index) }
        posters.onMenu = { [weak self] index in self?.menu(forTile: index) }
        posters.onEscape = { [weak self] in self?.escape() ?? false }
        detail.onPlay = { [weak self] channel in self?.choose(channel) }
        detail.onBack = { [weak self] in self?.closeShow() }
        recordings.onPlay = { [weak self] channel in self?.choose(channel) }
        recordings.onEscape = { [weak self] in self?.escape() ?? false }
        banner.onAction = { [weak self] in
            guard let self = self, let channel = self.bannerChannel else { return }
            self.choose(channel)
        }
        banner.onStar = { [weak self] in
            guard let channel = self?.bannerChannel else { return }
            Favorites.shared.toggle(channel)
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(libraryChanged), name: Library.didChange, object: nil)
        center.addObserver(self, selector: #selector(catalogChanged), name: CatalogStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(favoritesChanged), name: Favorites.didChange, object: nil)
        center.addObserver(self, selector: #selector(guideChanged), name: GuideStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(ratingsChanged), name: RatingsStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(ratingsChanged), name: PopularStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(recentsChanged), name: Recents.didChange, object: nil)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateStatus()
            self?.updateBanner()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        _ = CatalogStore.shared
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let narrow = view.bounds.width < 1020
        if wordmark.isHidden != narrow { wordmark.isHidden = narrow }
        let short = view.bounds.height < 600
        if short != bannerSuppressed {
            bannerSuppressed = short
            updateBanner()
        }
    }

    private var bannerSuppressed = false

    // MARK: - For the window

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func focusList() {
        let target: NSView
        if openShow != nil {
            target = detail.list
        } else {
            switch tab {
            case .live, .favorites: target = guide.table
            case .movies, .series: target = posters.collection
            case .recordings: target = recordings.list
            }
        }
        view.window?.makeFirstResponder(target)
    }

    /// The entry `offset` places away from `channel`: the next channel in
    /// the guide as it stands, or the next episode of the same show.
    func neighbor(of channel: Channel, offset: Int) -> Channel? {
        switch channel.kind {
        case .live:
            return guide.neighbor(of: channel, offset: offset)
        case .episode:
            let catalog = CatalogStore.shared.catalog
            guard let at = catalog.showOfEpisode[channel.url], at < catalog.shows.count else { return nil }
            return ShowDetailView.neighbor(of: channel.url, in: catalog.shows[at], offset: offset)
        case .movie:
            return nil
        }
    }

    /// The highlighted channel, if there is one.
    var highlighted: Channel? {
        switch tab {
        case .live, .favorites: return guide.highlighted
        default: return nil
        }
    }

    /// Move the highlight to the channel that is playing.
    func select(_ channel: Channel) {
        guard tab == .live || tab == .favorites else { return }
        guide.select(url: channel.url)
    }

    // MARK: - Choosing

    private func choose(_ channel: Channel) {
        delegate?.library(self, didChoose: channel)
    }

    /// Esc: leave a show's episodes, or give up choosing a channel.
    private func escape() -> Bool {
        if openShow != nil {
            closeShow()
            return true
        }
        if pickMessage != nil {
            delegate?.libraryDidCancelPick(self)
            return true
        }
        return false
    }

    @objc private func tabPressed(_ sender: NSButton) {
        guard let page = LibraryTab(rawValue: sender.tag) else { return }
        show(tab: page)
    }

    func show(tab page: LibraryTab) {
        guard page != tab || openShow != nil else { return }
        tab = page
        openShow = nil
        showPage()
        rebuildChips()
        runSearch()
    }

    /// Put the right page in view for the tab, and paint the tabs.
    private func showPage() {
        for button in tabButtons { button.isOn = button.tag == tab.rawValue }
        let inShow = openShow != nil
        guide.isHidden = inShow || !(tab == .live || tab == .favorites)
        posters.isHidden = inShow || !(tab == .movies || tab == .series)
        recordings.isHidden = inShow || tab != .recordings
        detail.isHidden = !inShow
        chipsRow.isHidden = inShow || tab == .favorites || tab == .recordings
        (searchField.cell as? NSTextFieldCell)?.placeholderAttributedString = NSAttributedString(
            string: tab.searchPrompt,
            attributes: [.foregroundColor: Theme.muted, .font: NSFont.systemFont(ofSize: 13.5)])
        searchField.needsDisplay = true
        browseButton.rename(tab == .live ? "All groups" : "All genres")
        updateBanner()
    }

    private func openTile(_ index: Int) {
        let store = CatalogStore.shared
        switch tab {
        case .movies:
            guard index < movieHits.count, movieHits[index] < store.catalog.movies.count,
                  let channel = store.channel(at: store.catalog.movies[movieHits[index]].channel) else { return }
            choose(channel)
        case .series:
            guard index < showHits.count, showHits[index] < store.catalog.shows.count else { return }
            open(show: store.catalog.shows[showHits[index]])
        default:
            break
        }
    }

    private func open(show: ShowItem) {
        openShow = show.folded
        detail.open(show)
        showPage()
        updateEmptyState()
        view.window?.makeFirstResponder(detail.list)
    }

    private func closeShow() {
        guard openShow != nil else { return }
        openShow = nil
        showPage()
        updateEmptyState()
        focusList()
    }

    private func menu(forTile index: Int) -> NSMenu? {
        let store = CatalogStore.shared
        let menu = NSMenu()
        switch tab {
        case .movies:
            guard index < movieHits.count, movieHits[index] < store.catalog.movies.count,
                  let channel = store.channel(at: store.catalog.movies[movieHits[index]].channel) else { return nil }
            let play = NSMenuItem(title: "Play", action: #selector(menuPlay(_:)), keyEquivalent: "")
            play.target = self
            play.representedObject = channel.url
            menu.addItem(play)
            let starred = Favorites.shared.contains(channel)
            let star = NSMenuItem(title: starred ? "Remove from Favorites" : "Add to Favorites",
                                  action: #selector(menuStar(_:)), keyEquivalent: "")
            star.target = self
            star.representedObject = channel.url
            menu.addItem(star)
            if ResumePoints.shared.position(for: channel.url) > 0 {
                let over = NSMenuItem(title: "Play from the Beginning", action: #selector(menuStartOver(_:)),
                                      keyEquivalent: "")
                over.target = self
                over.representedObject = channel.url
                menu.addItem(over)
            }
        case .series:
            let open = NSMenuItem(title: "Show Episodes", action: #selector(menuOpen(_:)), keyEquivalent: "")
            open.target = self
            open.tag = index
            menu.addItem(open)
        default:
            return nil
        }
        return menu
    }

    @objc private func menuPlay(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let channel = CatalogStore.shared.channel(url: url) else { return }
        choose(channel)
    }

    @objc private func menuStar(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let channel = CatalogStore.shared.channel(url: url) else { return }
        Favorites.shared.toggle(channel)
    }

    @objc private func menuStartOver(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String,
              let channel = CatalogStore.shared.channel(url: url) else { return }
        ResumePoints.shared.forget(url: url)
        Recents.shared.forget(url: url)
        choose(channel)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        openTile(sender.tag)
    }

    // MARK: - Genre chips

    private var chipSource: [GroupCount] {
        switch tab {
        case .live: return groups
        case .movies: return CatalogStore.shared.catalog.movieGenres
        case .series: return CatalogStore.shared.catalog.showGenres
        default: return []
        }
    }

    private func chipTitle(_ name: String) -> String {
        name.isEmpty ? "No category" : name
    }

    /// The chips for the tab on show. A long list shows its first forty
    /// here; every one is in the menu at the end of the row.
    private func rebuildChips() {
        let source = chipSource
        if let chosen = genre[tab], !source.contains(where: { $0.name == chosen }) {
            genre[tab] = nil
        }
        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var names: [String?] = [nil]
        names += source.prefix(40).map { Optional($0.name) }
        if let chosen = genre[tab], !names.contains(where: { $0 == chosen }) {
            names.insert(chosen, at: 1)
        }
        chipNames = names
        let chosen = genre[tab]
        for (i, name) in names.enumerated() {
            let chip = PillButton(name.map(chipTitle) ?? "All", look: .chip,
                                  target: self, action: #selector(chipPressed(_:)))
            chip.tag = i
            chip.isOn = name == chosen
            chipStack.addArrangedSubview(chip)
        }
        browseButton.isHidden = source.count <= 8
        chipScroll.contentView.scroll(to: .zero)
        chipScroll.reflectScrolledClipView(chipScroll.contentView)
    }

    @objc private func chipPressed(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < chipNames.count else { return }
        setGenre(chipNames[sender.tag])
    }

    private func setGenre(_ name: String?) {
        guard genre[tab] != name else { return }
        genre[tab] = name
        if !chipNames.contains(where: { $0 == name }) {
            rebuildChips()
        } else {
            for case let chip as PillButton in chipStack.arrangedSubviews {
                chip.isOn = chip.tag < chipNames.count && chipNames[chip.tag] == name
            }
        }
        runSearch()
    }

    @objc private func browsePressed() {
        let menu = NSMenu()
        let all = NSMenuItem(title: "All", action: #selector(browseChosen(_:)), keyEquivalent: "")
        all.target = self
        all.tag = -1
        all.state = genre[tab] == nil ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())
        for (i, group) in chipSource.enumerated() {
            let item = NSMenuItem(title: "\(chipTitle(group.name))   \(count(group.count))",
                                  action: #selector(browseChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = genre[tab] == group.name ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: browseButton.bounds.height + 6), in: browseButton)
    }

    @objc private func browseChosen(_ sender: NSMenuItem) {
        let source = chipSource
        if sender.tag < 0 {
            setGenre(nil)
        } else if sender.tag < source.count {
            setGenre(source[sender.tag].name)
        }
    }

    // MARK: - Searching

    func controlTextDidChange(_ obj: Notification) {
        if openShow != nil {
            openShow = nil
            showPage()
        }
        runSearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                runSearch()
                return true
            }
            return escape()
        }
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            focusList()
            return true
        }
        return false
    }

    @objc private func libraryChanged() {
        let library = Library.shared
        if library.revision != shownLibraryRevision {
            shownLibraryRevision = library.revision
            groups = Groups.list(in: library.channels, kind: .live)
            if tab == .live { rebuildChips() }
            if tab == .live || tab == .favorites { runSearch() }
        }
        refreshButton.isEnabled = !library.isRefreshing
        updateStatus()
        updateEmptyState()
    }

    @objc private func catalogChanged() {
        let store = CatalogStore.shared
        guard store.revision != shownCatalogRevision else { return }
        shownCatalogRevision = store.revision
        RatingsStore.shared.refreshIfDue()
        PopularStore.shared.refreshIfDue()
        if tab == .movies || tab == .series {
            rebuildChips()
            runSearch()
        }
        if let key = openShow {
            if let show = store.catalog.shows.first(where: { $0.folded == key }) {
                detail.open(show)
            } else {
                closeShow()
            }
        }
        updateBanner()
        updateStatus()
    }

    @objc private func favoritesChanged() {
        if tab == .favorites { runSearch() }
        guide.redraw()
        updateBanner()
    }

    @objc private func guideChanged() {
        guide.redraw()
        updateBanner()
    }

    @objc private func ratingsChanged() {
        if (tab == .movies || tab == .series) && openShow == nil {
            // the top row is chosen by rating, so work the page out again
            runSearch()
        } else {
            posters.redraw()
        }
    }

    @objc private func recentsChanged() {
        updateBanner()
    }

    /// Work out the page again from the box, the tab and the chip.
    private func runSearch() {
        let query = searchField.stringValue
        clearButton.isHidden = query.isEmpty
        let page = tab
        let chosen = genre[page]
        let ratings = RatingsStore.shared.lookup
        let chart = PopularStore.shared.chart
        let question = "\(page.rawValue)\u{1}\(chosen ?? "\u{2}")\u{1}\(query)"
        let ticket = self.ticket
        let mine = ticket.next()
        let cancelled: () -> Bool = { ticket.current != mine }

        switch page {
        case .live, .favorites:
            let list = Library.shared.channels
            let urls: Set<String>? = page == .favorites ? Favorites.shared.urls : nil
            let kind: ChannelKind? = page == .live ? .live : nil
            searchQueue.async { [weak self] in
                guard let found = Search.matches(in: list, query: query, kind: kind,
                                                 group: page == .live ? chosen : nil,
                                                 urls: urls, cancelled: cancelled) else { return }
                let rows = found.map { list[$0] }
                DispatchQueue.main.async {
                    guard let self = self, ticket.current == mine else { return }
                    let fresh = question != self.shownQuestion
                    self.shownQuestion = question
                    self.hasAnswer = true
                    self.resultCount = rows.count
                    self.guide.show(rows, reveal: fresh)
                    self.updateStatus()
                    self.updateEmptyState()
                    self.updateBanner()
                }
            }
        case .movies:
            let store = CatalogStore.shared
            let movies = store.catalog.movies
            let channels = store.channels
            let words = Search.words(query)
            searchQueue.async { [weak self] in
                var hits: [Int] = []
                hits.reserveCapacity(words.isEmpty && chosen == nil ? movies.count : 256)
                for (i, movie) in movies.enumerated() {
                    if i & 0x3FFF == 0 && cancelled() { return }
                    if let chosen = chosen, !movie.genres.contains(chosen) { continue }
                    if words.contains(where: { !movie.folded.contains($0) }) { continue }
                    hits.append(i)
                }
                // the ten best rated of what is listed, each film once
                var top: [Int] = []
                if words.isEmpty && !chart.movies.isEmpty {
                    // this week's most popular, in the chart's order
                    var keys: [(key: String, year: Int, index: Int)] = []
                    keys.reserveCapacity(hits.count)
                    for (n, i) in hits.enumerated() {
                        if n & 0xFFF == 0 && cancelled() { return }
                        keys.append((Titles.key(movies[i].title), movies[i].year ?? 0, i))
                    }
                    top = LibraryViewController.popular(chart.movies, among: keys)
                    if top.count < 5 { top = [] }
                }
                if words.isEmpty && top.isEmpty {
                    var rated: [(index: Int, rating: Double, year: Int)] = []
                    for (n, i) in hits.enumerated() {
                        if n & 0xFFF == 0 && cancelled() { return }
                        let movie = movies[i]
                        guard movie.channel < channels.count else { continue }
                        let channel = channels[movie.channel]
                        guard let rating = ratings.movie(url: channel.url, name: channel.name),
                              rating <= LibraryViewController.topCeiling else { continue }
                        rated.append((i, rating, movie.year ?? 0))
                    }
                    rated.sort {
                        if $0.rating != $1.rating { return $0.rating > $1.rating }
                        if $0.year != $1.year { return $0.year > $1.year }
                        return $0.index < $1.index
                    }
                    var seen = Set<String>()
                    for entry in rated {
                        guard seen.insert("\(movies[entry.index].folded)|\(entry.year)").inserted else { continue }
                        top.append(entry.index)
                        if top.count == 10 { break }
                    }
                    if top.count < 5 { top = [] }
                }
                let listed = hits.count
                hits = top + hits
                let lead = top.count
                DispatchQueue.main.async {
                    guard let self = self, ticket.current == mine else { return }
                    let fresh = question != self.shownQuestion
                    self.shownQuestion = question
                    self.hasAnswer = true
                    self.movieHits = hits
                    self.resultCount = listed
                    self.posters.show(count: hits.count, lead: lead,
                                      leadTitle: LibraryViewController.topTitle(lead, chosen, "Movies"),
                                      restTitle: chosen ?? "All Movies", toTop: fresh) { index in
                        guard index < hits.count, hits[index] < movies.count else { return PosterTile() }
                        let movie = movies[hits[index]]
                        guard movie.channel < channels.count else { return PosterTile() }
                        let channel = channels[movie.channel]
                        var parts: [String] = []
                        if let year = movie.year { parts.append(String(year)) }
                        if let first = movie.genres.first(where: { !$0.lowercased().contains("latest") }) {
                            parts.append(first)
                        }
                        return PosterTile(title: movie.title, detail: parts.joined(separator: " · "),
                                          poster: channel.logo,
                                          rating: RatingsStore.text(RatingsStore.shared.movie(url: channel.url, name: channel.name)),
                                          rank: index < lead ? index + 1 : nil)
                    }
                    self.updateStatus()
                    self.updateEmptyState()
                }
            }
        case .series:
            let shows = CatalogStore.shared.catalog.shows
            let words = Search.words(query)
            searchQueue.async { [weak self] in
                var hits: [Int] = []
                for (i, show) in shows.enumerated() {
                    if i & 0x3FFF == 0 && cancelled() { return }
                    if let chosen = chosen, !show.genres.contains(chosen) { continue }
                    if words.contains(where: { !show.folded.contains($0) }) { continue }
                    hits.append(i)
                }
                var top: [Int] = []
                if words.isEmpty && !chart.shows.isEmpty {
                    var keys: [(key: String, year: Int, index: Int)] = []
                    for (n, i) in hits.enumerated() {
                        if n & 0xFFF == 0 && cancelled() { return }
                        let name = shows[i].name
                        keys.append((Titles.key(name), 0, i))
                        let bare = Titles.movie(name).title
                        if bare != name { keys.append((Titles.key(bare), 0, i)) }
                    }
                    top = LibraryViewController.popular(chart.shows, among: keys)
                    if top.count < 5 { top = [] }
                }
                if words.isEmpty && top.isEmpty {
                    var rated: [(index: Int, rating: Double, size: Int)] = []
                    for (n, i) in hits.enumerated() {
                        if n & 0xFFF == 0 && cancelled() { return }
                        guard let rating = ratings.show(name: shows[i].name),
                              rating <= LibraryViewController.topCeiling else { continue }
                        rated.append((i, rating, shows[i].episodes.count))
                    }
                    rated.sort {
                        if $0.rating != $1.rating { return $0.rating > $1.rating }
                        if $0.size != $1.size { return $0.size > $1.size }
                        return $0.index < $1.index
                    }
                    top = rated.prefix(10).map { $0.index }
                    if top.count < 5 { top = [] }
                }
                let listed = hits.count
                hits = top + hits
                let lead = top.count
                DispatchQueue.main.async {
                    guard let self = self, ticket.current == mine else { return }
                    let fresh = question != self.shownQuestion
                    self.shownQuestion = question
                    self.hasAnswer = true
                    self.showHits = hits
                    self.resultCount = listed
                    self.posters.show(count: hits.count, lead: lead,
                                      leadTitle: LibraryViewController.topTitle(lead, chosen, "Series"),
                                      restTitle: chosen ?? "All Series", toTop: fresh) { index in
                        guard index < hits.count, hits[index] < shows.count else { return PosterTile() }
                        let show = shows[hits[index]]
                        var parts: [String] = []
                        let seasons = show.seasons.count
                        parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons")
                        if let first = show.genres.first(where: { !$0.lowercased().contains("latest") }) {
                            parts.append(first)
                        }
                        return PosterTile(title: show.name, detail: parts.joined(separator: " · "),
                                          poster: show.poster,
                                          rating: RatingsStore.text(RatingsStore.shared.show(name: show.name)),
                                          rank: index < lead ? index + 1 : nil)
                    }
                    self.updateStatus()
                    self.updateEmptyState()
                }
            }
        case .recordings:
            recordings.reload()
            shownQuestion = question
            hasAnswer = true
            resultCount = recordings.files.count
            updateStatus()
            updateEmptyState()
        }
    }

    /// A rating above this nearly always rests on one or two votes, so it
    /// is left out of the top row.
    private static let topCeiling = 9.3

    /// The first ten of the chart that are in the library, in the chart's
    /// order. A year may be missing on either side, or a year out.
    private static func popular(_ chart: [PopularStore.Entry],
                                among keys: [(key: String, year: Int, index: Int)]) -> [Int] {
        var byKey: [String: [(year: Int, index: Int)]] = [:]
        for entry in keys where !entry.key.isEmpty {
            byKey[entry.key, default: []].append((entry.year, entry.index))
        }
        var out: [Int] = []
        var used = Set<Int>()
        for entry in chart {
            guard let found = byKey[entry.key] else { continue }
            let exact = found.first(where: { entry.year != 0 && $0.year == entry.year })
            let near = found.first(where: { $0.year == 0 || entry.year == 0 || abs($0.year - entry.year) <= 1 })
            guard let chosen = exact ?? near, used.insert(chosen.index).inserted else { continue }
            out.append(chosen.index)
            if out.count == 10 { break }
        }
        return out
    }

    private static func topTitle(_ count: Int, _ genre: String?, _ kind: String) -> String {
        let lead = count == 10 ? "Top 10" : "Top \(count)"
        if let genre = genre { return "\(lead) in \(genre)" }
        return "\(lead) \(kind)"
    }

    // MARK: - The banner

    /// What the wide panel shows: the highlighted channel on the guide
    /// pages, the film or episode to carry on with on the poster pages.
    private func updateBanner() {
        guard isViewLoaded else { return }
        bannerChannel = nil
        var visible = false
        if openShow == nil && !bannerSuppressed {
            switch tab {
            case .live, .favorites:
                // the guide stands alone: a click on a channel opens it
                break
            case .movies, .series:
                visible = showResume(kind: tab == .movies ? .movie : .episode)
            case .recordings:
                break
            }
        }
        if banner.isHidden == visible { banner.isHidden = !visible }
    }

    private func showResume(kind: ChannelKind) -> Bool {
        let store = CatalogStore.shared
        for entry in Recents.shared.entries {
            guard let channel = store.channel(url: entry.url), channel.kind == kind,
                  ResumePoints.shared.position(for: entry.url) > 0 else { continue }
            let left = entry.lengthMs > entry.positionMs
                ? "\(Theme.span(Double(entry.lengthMs - entry.positionMs) / 1000)) left"
                : "\(Theme.span(Double(entry.positionMs) / 1000)) in"
            let fraction = entry.lengthMs > 0 ? CGFloat(entry.positionMs) / CGFloat(entry.lengthMs) : 0.5
            var title = channel.name
            var parts: [String] = []
            var poster = channel.logo
            if kind == .movie {
                let parsed = Titles.movie(channel.name)
                title = parsed.title
                if let rating = RatingsStore.text(RatingsStore.shared.movie(url: channel.url, name: channel.name)) {
                    parts.append("★ \(rating)")
                }
                if let year = parsed.year { parts.append(String(year)) }
            } else if let parsed = Titles.episode(channel.name) {
                title = parsed.show
                if let rating = RatingsStore.text(RatingsStore.shared.show(name: parsed.show)) {
                    parts.append("★ \(rating)")
                }
                parts.append("Season \(parsed.season), episode \(parsed.episode)")
                if poster.isEmpty, let at = store.catalog.showOfEpisode[channel.url], at < store.catalog.shows.count {
                    poster = store.catalog.shows[at].poster
                }
            }
            parts.append(left)
            bannerChannel = channel
            banner.show(resume: title, detail: parts.joined(separator: "   "), poster: poster, fraction: fraction)
            return true
        }
        return false
    }

    // MARK: - Buttons

    /// The x in the search box: empty it and show everything again.
    @objc private func clearPressed() {
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        if openShow != nil {
            openShow = nil
            showPage()
        }
        runSearch()
        focusSearch()
    }

    @objc private func refreshPressed() {
        Library.shared.refresh()
    }

    @objc private func backPressed() {
        delegate?.libraryDidCancelPick(self)
    }

    @objc private func settingsPressed() {
        delegate?.libraryDidRequestSettings(self)
    }

    // MARK: - Words on screen

    private func count(_ n: Int) -> String {
        LibraryViewController.numbers.string(from: NSNumber(value: n)) ?? String(n)
    }

    private func updateStatus() {
        guard isViewLoaded else { return }
        let library = Library.shared
        var parts: [String] = []
        if hasAnswer && !library.channels.isEmpty {
            switch tab {
            case .live: parts.append("\(count(resultCount)) channels")
            case .movies: parts.append("\(count(resultCount)) movies")
            case .series: parts.append("\(count(resultCount)) series")
            case .favorites: parts.append("\(count(resultCount)) favorites")
            case .recordings: parts.append("\(count(resultCount)) recordings")
            }
            parts.append("\(count(library.channels.count)) entries in your playlist, every one kept")
        }
        if library.isRefreshing {
            parts.append("Refreshing channels…")
        } else if let error = library.lastError {
            parts.append(error)
        } else {
            let stamp = ConfigStore.shared.config.lastRefresh
            if stamp > 0 {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let seconds = Date().timeIntervalSince1970 - stamp
                let when = seconds < 60 ? "just now"
                    : formatter.localizedString(for: Date(timeIntervalSince1970: stamp), relativeTo: Date())
                parts.append("Updated \(when)")
            }
        }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        statusLabel.textColor = (library.lastError != nil && !library.isRefreshing) ? Theme.gold : Theme.muted
    }

    private func updateEmptyState() {
        guard isViewLoaded else { return }
        let library = Library.shared
        var text = ""
        var button = false
        if openShow != nil {
            text = ""
        } else if tab == .recordings {
            if recordings.files.isEmpty {
                text = "No recordings yet. While watching a channel, choose Record to save it here."
            }
        } else if !library.hasSource && library.channels.isEmpty {
            text = "Add your playlist link in Settings to load your channels."
            button = true
        } else if library.channels.isEmpty {
            if library.isRefreshing {
                text = "Fetching your playlist…"
            } else if let error = library.lastError {
                text = error
                button = true
            } else {
                text = "No channels yet. Press Refresh Channels."
            }
        } else if (tab == .movies || tab == .series) && CatalogStore.shared.revision != library.revision {
            text = "Arranging your \(tab == .movies ? "movies" : "series")…"
        } else if hasAnswer && resultCount == 0 {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                text = "Nothing matches “\(query)”."
            } else if tab == .favorites {
                text = "No favorites yet. Click the star beside a channel to add it."
            } else {
                text = "Nothing here."
            }
        }
        emptyLabel.stringValue = text
        emptyButton.isHidden = !button
        emptyStack.isHidden = text.isEmpty
    }

    // MARK: - For the pictures taken by the build

    /// Put a named page on screen. Returns false when there is nothing to
    /// show for it.
    func stage(_ name: String) -> Bool {
        // nothing typed on this Mac while the pictures are taken may land
        // in the search box
        searchField.isEditable = false
        searchField.isSelectable = false
        view.window?.makeFirstResponder(nil)
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            runSearch()
        }
        switch name {
        case "live": show(tab: .live)
        case "movies": show(tab: .movies)
        case "series": show(tab: .series)
        case "favorites": show(tab: .favorites)
        case "recordings": show(tab: .recordings)
        case "search":
            show(tab: .movies)
            searchField.stringValue = "the"
            runSearch()
        case "show":
            show(tab: .series)
            guard let first = CatalogStore.shared.catalog.shows.max(by: { $0.episodes.count < $1.episodes.count })
            else { return false }
            open(show: first)
        case "pick":
            show(tab: .live)
            pickMessage = "Choose a channel to watch beside the one playing. Esc goes back."
        default:
            return false
        }
        return true
    }
}
