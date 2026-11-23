import AppKit
import TuberCore

/// What one poster tile says.
struct PosterTile {
    var title = ""
    var detail = ""
    var poster = ""
    var rating: String?
    /// 1 to 10 for a tile in the top row.
    var rank: Int?
}

/// Posters in even columns. The arithmetic is direct, so fifty thousand
/// films cost no more to lay out than fifty.
final class PosterLayout: NSCollectionViewLayout {
    var count = 0
    /// How many of the first tiles form the top row.
    var lead = 0
    private var leadColumns = 10
    private var leadWidth: CGFloat = 100
    private var leadHeight: CGFloat = 196
    private var gridTop: CGFloat = PosterLayout.top
    private var columns = 2
    private var itemWidth: CGFloat = 150
    private var itemHeight: CGFloat = 270
    private(set) var width: CGFloat = 0

    static let side: CGFloat = 40
    static let gapX: CGFloat = 18
    static let gapY: CGFloat = 20
    static let top: CGFloat = 6
    static let textHeight: CGFloat = 46
    static let headerHeight: CGFloat = 38
    static let headerKind = NSCollectionView.elementKindSectionHeader

    private var leadTop: CGFloat { PosterLayout.top + PosterLayout.headerHeight }
    private var leadRows: Int { lead > 0 ? (lead + leadColumns - 1) / leadColumns : 0 }
    private var secondHeaderTop: CGFloat {
        leadTop + CGFloat(leadRows) * (leadHeight + PosterLayout.gapY)
    }

    private func headerFrame(_ item: Int) -> NSRect {
        NSRect(x: 0, y: item == 0 ? PosterLayout.top : secondHeaderTop,
               width: width, height: PosterLayout.headerHeight)
    }

    private func header(_ item: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(
            forSupplementaryViewOfKind: PosterLayout.headerKind, with: IndexPath(item: item, section: 0))
        attributes.frame = headerFrame(item)
        return attributes
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard lead > 0, indexPath.item == 0 || indexPath.item == 1 else { return nil }
        return header(indexPath.item)
    }

    override func prepare() {
        super.prepare()
        width = collectionView?.enclosingScrollView?.contentSize.width ?? collectionView?.bounds.width ?? 0
        let usable = max(240, width - PosterLayout.side * 2)
        columns = max(2, Int((usable + PosterLayout.gapX) / (150 + PosterLayout.gapX)))
        itemWidth = ((usable - CGFloat(columns - 1) * PosterLayout.gapX) / CGFloat(columns)).rounded(.down)
        itemHeight = (itemWidth * 1.5).rounded(.down) + PosterLayout.textHeight
        lead = max(0, min(lead, count))
        // ten across when there is room, otherwise two rows of five
        leadColumns = usable >= 1060 ? 10 : 5
        leadWidth = ((usable - CGFloat(leadColumns - 1) * PosterLayout.gapX) / CGFloat(leadColumns)).rounded(.down)
        leadHeight = (leadWidth * 1.5).rounded(.down) + PosterLayout.textHeight
        gridTop = lead > 0 ? secondHeaderTop + PosterLayout.headerHeight : PosterLayout.top
    }

    var columnCount: Int { columns }

    override var collectionViewContentSize: NSSize {
        let rows = (max(0, count - lead) + columns - 1) / columns
        let height = gridTop + CGFloat(rows) * (itemHeight + PosterLayout.gapY) + 20
        return NSSize(width: width, height: height)
    }

    private func frame(_ index: Int) -> NSRect {
        if index < lead {
            let row = index / leadColumns
            let column = index % leadColumns
            return NSRect(x: PosterLayout.side + CGFloat(column) * (leadWidth + PosterLayout.gapX),
                          y: leadTop + CGFloat(row) * (leadHeight + PosterLayout.gapY),
                          width: leadWidth, height: leadHeight)
        }
        let place = index - lead
        let row = place / columns
        let column = place % columns
        return NSRect(x: PosterLayout.side + CGFloat(column) * (itemWidth + PosterLayout.gapX),
                      y: gridTop + CGFloat(row) * (itemHeight + PosterLayout.gapY),
                      width: itemWidth, height: itemHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard count > 0 else { return [] }
        var out: [NSCollectionViewLayoutAttributes] = []
        if lead > 0 {
            for item in 0...1 where headerFrame(item).intersects(rect) {
                out.append(header(item))
            }
            for index in 0..<lead where frame(index).intersects(rect) {
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
                attributes.frame = frame(index)
                out.append(attributes)
            }
        }
        guard count > lead, rect.maxY >= gridTop else { return out }
        let pitch = itemHeight + PosterLayout.gapY
        let firstRow = max(0, Int((rect.minY - gridTop) / pitch))
        let lastRow = max(firstRow, Int((rect.maxY - gridTop) / pitch))
        let first = lead + firstRow * columns
        let last = min(count - 1, lead + (lastRow + 1) * columns - 1)
        guard first <= last else { return out }
        out.reserveCapacity(out.count + last - first + 1)
        for index in first...last {
            let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            attributes.frame = frame(index)
            out.append(attributes)
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        attributes.frame = frame(indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        let now = collectionView?.enclosingScrollView?.contentSize.width ?? newBounds.width
        return abs(now - width) > 0.5
    }
}

/// The words above the top row and above the rest.
final class PosterHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PosterHeader")
    let label = Theme.label(font: Theme.serif(19), color: Theme.text)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PosterLayout.side + 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PosterLayout.side),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("PosterHeader is built in code")
    }
}

/// One poster with its title, rating and a line of detail.
final class PosterItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PosterItem")

    private let art = ArtView(shape: .poster)
    private let ring = Box(color: .clear, radius: Theme.posterRadius + 3)
    private let titleLabel = Theme.label(font: NSFont.systemFont(ofSize: 13, weight: .semibold), color: Theme.text)
    private let starView = NSImageView()
    private let ratingLabel = Theme.label(font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                                          color: Theme.gold)
    private let detailLabel = Theme.label(font: NSFont.systemFont(ofSize: 12), color: Theme.muted)
    private let rankBadge = Box(color: Theme.gold, radius: 14)
    private let rankLabel = Theme.label(font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .heavy),
                                        color: Theme.onGold)
    private var detailLeading: NSLayoutConstraint?
    private var detailLeadingPlain: NSLayoutConstraint?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        ring.layer?.borderWidth = 2
        ring.layer?.borderColor = NSColor.clear.cgColor
        starView.image = Theme.symbol("star.fill", "Rating", size: 10, weight: .bold)
        starView.contentTintColor = Theme.gold
        starView.translatesAutoresizingMaskIntoConstraints = false
        ratingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        ratingLabel.setContentHuggingPriority(.required, for: .horizontal)

        root.addSubview(ring)
        root.addSubview(art)
        root.addSubview(titleLabel)
        root.addSubview(starView)
        root.addSubview(ratingLabel)
        root.addSubview(detailLabel)
        rankLabel.alignment = .center
        rankBadge.addSubview(rankLabel)
        rankBadge.layer?.borderColor = Theme.ground.cgColor
        rankBadge.layer?.borderWidth = 2
        rankBadge.isHidden = true
        root.addSubview(rankBadge)
        NSLayoutConstraint.activate([
            rankBadge.topAnchor.constraint(equalTo: art.topAnchor, constant: 7),
            rankBadge.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: 7),
            rankBadge.heightAnchor.constraint(equalToConstant: 28),
            rankBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            rankLabel.centerYAnchor.constraint(equalTo: rankBadge.centerYAnchor),
            rankLabel.leadingAnchor.constraint(equalTo: rankBadge.leadingAnchor, constant: 7),
            rankLabel.trailingAnchor.constraint(equalTo: rankBadge.trailingAnchor, constant: -7),
        ])

        let withRating = detailLabel.leadingAnchor.constraint(equalTo: ratingLabel.trailingAnchor, constant: 7)
        let plain = detailLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2)
        detailLeading = withRating
        detailLeadingPlain = plain
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: root.topAnchor),
            art.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            art.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -PosterLayout.textHeight),
            ring.topAnchor.constraint(equalTo: art.topAnchor, constant: -3),
            ring.leadingAnchor.constraint(equalTo: art.leadingAnchor, constant: -3),
            ring.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: 3),
            ring.bottomAnchor.constraint(equalTo: art.bottomAnchor, constant: 3),
            titleLabel.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            starView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            starView.centerYAnchor.constraint(equalTo: ratingLabel.centerYAnchor),
            ratingLabel.leadingAnchor.constraint(equalTo: starView.trailingAnchor, constant: 3),
            ratingLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.centerYAnchor.constraint(equalTo: ratingLabel.centerYAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -2),
            withRating,
        ])
    }

    func show(_ tile: PosterTile) {
        titleLabel.stringValue = tile.title
        view.toolTip = tile.title
        detailLabel.stringValue = tile.detail
        art.show(address: tile.poster, name: tile.title, maxPixel: 420)
        let rated = tile.rating != nil
        // a label keeps its line even when empty, so the row never jumps
        ratingLabel.stringValue = tile.rating ?? " "
        starView.isHidden = !rated
        detailLeading?.isActive = rated
        detailLeadingPlain?.isActive = !rated
        rankBadge.isHidden = tile.rank == nil
        rankLabel.stringValue = tile.rank.map { String($0) } ?? ""
        var spoken = tile.rank.map { "Number \($0), " } ?? ""
        spoken += tile.title
        if let rating = tile.rating { spoken += ", rated \(rating)" }
        if !tile.detail.isEmpty { spoken += ", \(tile.detail)" }
        view.setAccessibilityLabel(spoken)
        view.setAccessibilityRole(.button)
    }

    override var isSelected: Bool {
        didSet {
            ring.layer?.borderColor = (isSelected ? Theme.gold : NSColor.clear).cgColor
        }
    }
}

/// A collection view that opens a tile with one click or with Return.
final class PosterCollectionView: NSCollectionView {
    var onOpen: ((Int) -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    /// Returns true when Esc was used.
    var onEscape: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let before = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, let window = window else { return }
        // only a press and release on the same tile counts as a click
        let after = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let down = indexPathForItem(at: before), let up = indexPathForItem(at: after),
              down == up else { return }
        onOpen?(down.item)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let chosen = selectionIndexPaths.first { onOpen?(chosen.item) }
        } else if event.keyCode == 53, onEscape?() == true {
            // used
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        selectionIndexPaths = [path]
        return onMenu?(path.item)
    }
}

/// A wall of posters.
final class PosterGridView: NSView, NSCollectionViewDataSource {
    var onOpen: ((Int) -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    var onEscape: (() -> Bool)?

    let collection = PosterCollectionView()
    private let scroll = NSScrollView()
    private let layoutEngine = PosterLayout()
    private var count = 0
    private var provider: (Int) -> PosterTile = { _ in PosterTile() }
    private var leadTitle = ""
    private var restTitle = ""
    private var lastWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        collection.collectionViewLayout = layoutEngine
        collection.register(PosterItem.self, forItemWithIdentifier: PosterItem.identifier)
        collection.register(PosterHeader.self, forSupplementaryViewOfKind: PosterLayout.headerKind,
                            withIdentifier: PosterHeader.identifier)
        collection.dataSource = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.onOpen = { [weak self] index in self?.onOpen?(index) }
        collection.onMenu = { [weak self] index in self?.onMenu?(index) }
        collection.onEscape = { [weak self] in self?.onEscape?() ?? false }
        collection.setAccessibilityLabel("Posters")

        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("PosterGridView is built in code")
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            layoutEngine.invalidateLayout()
        }
    }

    /// Replace the tiles. `provider` is asked only for the ones on screen.
    /// The first `lead` tiles form a top row under `leadTitle`, and the
    /// rest follow under `restTitle`.
    func show(count: Int, lead: Int = 0, leadTitle: String = "", restTitle: String = "",
              toTop: Bool, provider: @escaping (Int) -> PosterTile) {
        self.count = count
        self.provider = provider
        self.leadTitle = leadTitle
        self.restTitle = restTitle
        layoutEngine.count = count
        layoutEngine.lead = max(0, min(lead, count))
        collection.reloadData()
        if toTop {
            collection.scroll(NSPoint(x: 0, y: 0))
        }
    }

    /// Repaint the tiles on screen, for when ratings arrive.
    func redraw() {
        for path in collection.indexPathsForVisibleItems() where path.item < count {
            (collection.item(at: path) as? PosterItem)?.show(provider(path.item))
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView,
                        viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PosterHeader.identifier,
                                                        for: indexPath)
        (view as? PosterHeader)?.label.stringValue = indexPath.item == 0 ? leadTitle : restTitle
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PosterItem.identifier, for: indexPath)
        if let poster = item as? PosterItem, indexPath.item < count {
            poster.show(provider(indexPath.item))
        }
        return item
    }
}
