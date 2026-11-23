import AppKit
import CryptoKit
import ImageIO

/// Fetches logos and posters, keeps them on disk, and hands back small
/// versions sized for the screen. These come from the picture hosts named
/// in the playlist, not from the provider's stream servers.
final class ImageLoader {
    static let shared = ImageLoader()

    /// A request that can be given up, for a tile that scrolled away.
    final class Token {
        private let lock = NSLock()
        private var stopped = false
        private var task: URLSessionDataTask?

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func attach(_ task: URLSessionDataTask) {
            lock.lock()
            let dead = stopped
            if !dead { self.task = task }
            lock.unlock()
            if dead { task.cancel() }
        }

        func cancel() {
            lock.lock()
            stopped = true
            let running = task
            task = nil
            lock.unlock()
            running?.cancel()
        }
    }

    private let memory = NSCache<NSString, CGImage>()
    /// Addresses that gave no picture this session. Main thread only.
    private var failed = Set<String>()
    private let work = DispatchQueue(label: "tuberview.images", qos: .utility, attributes: .concurrent)
    private let folder: URL
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.httpMaximumConnectionsPerHost = 6
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        folder = base.appendingPathComponent("TuberView/pictures", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.countLimit = 900
        work.async { [folder] in ImageLoader.prune(folder) }
    }

    /// Ask for a picture no larger than `maxPixel` on its long side. `done`
    /// is called on the main thread, at once when the picture is already in
    /// memory. Call on the main thread.
    @discardableResult
    func load(_ address: String, maxPixel: Int, done: @escaping (CGImage?) -> Void) -> Token? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            done(nil)
            return nil
        }
        let key = "\(maxPixel)|\(trimmed)"
        if let image = memory.object(forKey: key as NSString) {
            done(image)
            return nil
        }
        if failed.contains(trimmed) {
            done(nil)
            return nil
        }
        guard let url = Library.webURL(from: trimmed) else {
            done(nil)
            return nil
        }
        let token = Token()
        let file = folder.appendingPathComponent(ImageLoader.name(for: trimmed))
        work.async { [weak self] in
            guard let self = self, !token.isCancelled else { return }
            if let data = try? Data(contentsOf: file), let image = ImageLoader.shrink(data, maxPixel) {
                self.finish(image, key: key, address: trimmed, token: token, done: done)
                return
            }
            let task = self.session.dataTask(with: url) { [weak self] data, response, _ in
                guard let self = self else { return }
                var image: CGImage?
                if let data = data, !data.isEmpty,
                   (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                   data.count < 12_000_000 {
                    image = ImageLoader.shrink(data, maxPixel)
                    if image != nil { try? data.write(to: file, options: .atomic) }
                }
                let stopped = (response == nil && data == nil && token.isCancelled)
                if stopped { return }
                self.finish(image, key: key, address: trimmed, token: token, done: done)
            }
            token.attach(task)
            task.resume()
        }
        return token
    }

    private func finish(_ image: CGImage?, key: String, address: String, token: Token,
                        done: @escaping (CGImage?) -> Void) {
        DispatchQueue.main.async {
            if let image = image {
                self.memory.setObject(image, forKey: key as NSString)
            } else if !token.isCancelled {
                self.failed.insert(address)
            }
            if !token.isCancelled { done(image) }
        }
    }

    private static func name(for address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func shrink(_ data: Data, _ maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Keep the folder from growing for ever: past 12,000 pictures, the
    /// older half goes.
    private static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]),
              files.count > 12_000 else { return }
        let dated = files.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count / 2) {
            try? fm.removeItem(at: url)
        }
    }
}

/// Artwork with rounded corners: the picture when there is one, otherwise
/// a tinted panel with the name on it.
final class ArtView: NSView {
    enum Shape {
        /// A poster: the picture fills the panel.
        case poster
        /// A channel logo: the whole picture fits inside a circle.
        case logo
    }

    private let shape: Shape
    private let picture = CALayer()
    private let words: NSTextField
    private var token: ImageLoader.Token?
    private var shown = ""
    /// For a poster-shaped panel that is showing a logo: fit the whole
    /// picture inside instead of filling the panel with it.
    var fitsInside = false {
        didSet {
            guard fitsInside != oldValue, shape == .poster else { return }
            picture.contentsGravity = fitsInside ? .resizeAspect : .resizeAspectFill
            needsLayout = true
        }
    }

    init(shape: Shape) {
        self.shape = shape
        words = Theme.label(font: shape == .poster ? Theme.serif(16) : NSFont.systemFont(ofSize: 10.5, weight: .heavy),
                            color: NSColor.white.withAlphaComponent(0.92))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Theme.posterRadius
        picture.contentsGravity = shape == .poster ? .resizeAspectFill : .resizeAspect
        picture.masksToBounds = true
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)
        addSubview(words)
        if shape == .poster {
            words.maximumNumberOfLines = 4
            words.lineBreakMode = .byWordWrapping
            words.cell?.wraps = true
            words.cell?.truncatesLastVisibleLine = true
            NSLayoutConstraint.activate([
                words.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                words.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            ])
        } else {
            words.alignment = .center
            NSLayoutConstraint.activate([
                words.centerXAnchor.constraint(equalTo: centerXAnchor),
                words.centerYAnchor.constraint(equalTo: centerYAnchor),
                words.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -4),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("ArtView is built in code")
    }

    override func layout() {
        super.layout()
        if shape == .poster {
            // smaller letters on the small posters of the top row
            let size: CGFloat = bounds.width < 124 ? 12.5 : 16
            if words.font?.pointSize != size { words.font = Theme.serif(size) }
        }
        if shape == .logo {
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
            picture.frame = bounds.insetBy(dx: bounds.width * 0.14, dy: bounds.height * 0.14)
        } else if fitsInside {
            picture.frame = bounds.insetBy(dx: bounds.width * 0.14, dy: bounds.height * 0.14)
        } else {
            picture.frame = bounds
        }
    }

    /// Show the artwork at `address`, falling back to the name.
    func show(address: String, name: String, maxPixel: Int) {
        let key = address + "\u{1}" + name
        if key == shown { return }
        shown = key
        token?.cancel()
        token = nil
        picture.contents = nil
        words.stringValue = shape == .poster ? name : Theme.mark(for: name)
        words.isHidden = false
        layer?.backgroundColor = Theme.tint(for: name).cgColor
        guard !address.isEmpty else { return }
        token = ImageLoader.shared.load(address, maxPixel: maxPixel) { [weak self] image in
            guard let self = self, self.shown == key, let image = image else { return }
            self.picture.contents = image
            self.words.isHidden = true
            self.layer?.backgroundColor = (self.shape == .logo ? Theme.rgb(0x2A251F) : Theme.card).cgColor
        }
    }
}
