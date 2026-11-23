import AppKit

/// TuberView's look: warm charcoal, gold, rounded everywhere.
enum Theme {
    static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    static let ground = rgb(0x141210)
    static let bar = rgb(0x1A1714)
    static let line = rgb(0x2B2621)
    static let card = rgb(0x1E1A16)
    static let cardLine = rgb(0x2F2A24)
    static let field = rgb(0x231F1B)
    static let fieldLine = rgb(0x353029)
    static let chipLine = rgb(0x3A342C)
    static let outline = rgb(0x6B5E4C)

    static let text = rgb(0xF3EEE6)
    static let soft = rgb(0xCFC6B8)
    static let muted = rgb(0xA89F92)

    static let gold = rgb(0xF2B544)
    static let goldDim = rgb(0x3A2C12)
    static let onGold = rgb(0x1A1408)
    static let onGoldSoft = rgb(0x4A3708)
    static let track = rgb(0x4A4034)
    static let record = rgb(0xE5534B)

    static let posterRadius: CGFloat = 16

    private static func designed(_ design: NSFontDescriptor.SystemDesign, _ size: CGFloat,
                                 _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(design),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    /// The display face for titles.
    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .bold) -> NSFont {
        designed(.serif, size, weight)
    }

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        designed(.rounded, size, weight)
    }

    private static let tints: [Int] = [0x4A2F45, 0x24474F, 0x5A2D25, 0x33492F, 0x544020, 0x2F3857,
                                       0x3B4A33, 0x5B2E3D, 0x243F4F, 0x4F3A2A, 0x39324F, 0x2A4A4A]

    /// A steady colour for a name, for artwork that has not arrived or
    /// does not exist.
    static func tint(for name: String) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return rgb(tints[Int(hash % UInt32(tints.count))])
    }

    /// Up to four characters standing for a channel, when it has no logo.
    static func mark(for name: String) -> String {
        var text = name
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) <= 4 {
            text = String(text[text.index(after: colon)...])
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first else { return "TV" }
        if first.count <= 4 { return first.uppercased() }
        if words.count >= 2 {
            return String(words.prefix(3).compactMap { $0.first }).uppercased()
        }
        return String(first.prefix(3)).uppercased()
    }

    static func label(_ text: String = "", font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func symbol(_ name: String, _ description: String, size: CGFloat = 14,
                       weight: NSFont.Weight = .semibold) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func time(_ seconds: TimeInterval) -> String {
        clock.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// "1 hr 49 min" or "22 min".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
    }
}

/// A rounded button: a tab, a genre chip, or an action.
final class PillButton: NSButton {
    enum Look {
        case tab, chip, primary, outline
    }

    private let look: Look
    private var words: String
    var isOn = false {
        didSet { if isOn != oldValue { paint() } }
    }

    init(_ title: String, look: Look, symbol: String? = nil, target: AnyObject?, action: Selector?) {
        self.look = look
        self.words = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryChange)
        if let symbol = symbol, let image = Theme.symbol(symbol, title, size: 11, weight: .bold) {
            self.image = image
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        paint()
    }

    required init?(coder: NSCoder) {
        fatalError("PillButton is built in code")
    }

    func rename(_ title: String) {
        guard title != words else { return }
        words = title
        paint()
        invalidateIntrinsicContentSize()
    }

    private var height: CGFloat {
        switch look {
        case .tab: return 32
        case .chip: return 30
        case .primary, .outline: return 40
        }
    }

    private var pad: CGFloat {
        switch look {
        case .tab: return 16
        case .chip: return 14
        case .primary, .outline: return 22
        }
    }

    private var face: NSFont {
        switch look {
        case .tab: return NSFont.systemFont(ofSize: 13.5, weight: isOn ? .bold : .regular)
        case .chip: return NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        case .primary: return NSFont.systemFont(ofSize: 14.5, weight: .bold)
        case .outline: return NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        }
    }

    override var intrinsicContentSize: NSSize {
        let size = (words as NSString).size(withAttributes: [.font: face])
        let picture: CGFloat = image == nil ? 0 : 18
        return NSSize(width: ceil(size.width) + pad * 2 + picture, height: height)
    }

    private func paint() {
        var back = NSColor.clear
        var border = NSColor.clear
        var ink = Theme.soft
        switch look {
        case .tab:
            if isOn { back = Theme.gold; ink = Theme.onGold }
        case .chip:
            border = isOn ? Theme.gold : Theme.chipLine
            if isOn { back = Theme.goldDim; ink = Theme.gold }
        case .primary:
            back = Theme.gold
            ink = Theme.onGold
        case .outline:
            border = Theme.outline
            ink = Theme.text
        }
        layer?.cornerRadius = height / 2
        layer?.backgroundColor = back.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = border == .clear ? 0 : 1
        contentTintColor = ink
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: words, attributes: [
            .font: face, .foregroundColor: ink, .paragraphStyle: style,
        ])
        setAccessibilityLabel(words)
    }
}

/// A plain picture button from a system symbol.
final class IconButton: NSButton {
    init(symbol: String, tip: String, size: CGFloat = 15, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        focusRingType = .none
        title = ""
        toolTip = tip
        setAccessibilityLabel(tip)
        translatesAutoresizingMaskIntoConstraints = false
        show(symbol: symbol, size: size)
        contentTintColor = Theme.soft
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("IconButton is built in code")
    }

    func show(symbol: String, size: CGFloat = 15) {
        image = Theme.symbol(symbol, toolTip ?? "", size: size)
        imagePosition = .imageOnly
    }
}

/// A flat coloured box with rounded corners.
final class Box: NSView {
    init(color: NSColor, radius: CGFloat = 0, border: NSColor? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
        if let border = border {
            layer?.borderColor = border.cgColor
            layer?.borderWidth = 1
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Box is built in code")
    }

    func recolor(_ color: NSColor, border: NSColor? = nil) {
        layer?.backgroundColor = color.cgColor
        if let border = border { layer?.borderColor = border.cgColor }
    }
}

/// A thin bar showing how far through something is.
final class ProgressLine: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("ProgressLine is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Theme.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let done = max(0, min(1, fraction))
        guard done > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * done)
        Theme.gold.setFill()
        NSBezierPath(roundedRect: filled, xRadius: r, yRadius: r).fill()
    }
}
