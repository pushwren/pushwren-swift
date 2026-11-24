import Foundation
import UserNotifications

/// Downloads a push's image (`_i`) to a file and makes it an attachment. Apple attaches JPEG, GIF
/// and PNG images of at most 10 MB, from a file whose extension names the type; anything else,
/// or anything that goes wrong, means no attachment and the push shows without it.
struct ImageAttacher: Sendable {
    /// Apple's limit for image attachments, "10 MB", read as decimal megabytes.
    static let maxBytes = 10_000_000

    let session: URLSession
    /// Where downloads go until the system moves an attachment's file into its own store.
    let directory: URL

    /// The image URL, when the push has one this helper fetches: https only.
    static func imageURL(in userInfo: [AnyHashable: Any]) -> URL? {
        guard let string = userInfo["_i"] as? String, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Starts the download; `done` runs once, with the attachment or nil. Cancel the returned task
    /// to give up (its file is deleted and `done` gets nil).
    func start(_ url: URL, done: @escaping @Sendable (Attachment?) -> Void) -> URLSessionTask {
        let task = session.dataTask(with: url)
        task.delegate = Download(directory: directory, done: done)
        task.resume()
        return task
    }

    /// An attachment handed across threads. UNNotificationAttachment is immutable once made.
    struct Attachment: @unchecked Sendable {
        let value: UNNotificationAttachment
    }

    enum ImageType: CaseIterable {
        case jpeg, png, gif

        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .gif: "gif"
            }
        }

        /// The type by the file's first bytes, whatever the server said it was.
        init?(magic: Data) {
            let b = [UInt8](magic.prefix(8))
            if b.starts(with: [0xFF, 0xD8, 0xFF]) {
                self = .jpeg
            } else if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                self = .png
            } else if b.starts(with: Array("GIF87a".utf8)) || b.starts(with: Array("GIF89a".utf8)) {
                self = .gif
            } else {
                return nil
            }
        }
    }
}

/// One download's delegate. URLSession calls a task's delegate methods one at a time on the
/// session's serial delegate queue, so its state needs no lock.
private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let directory: URL
    private let done: @Sendable (ImageAttacher.Attachment?) -> Void
    private let partial: URL
    private var file: FileHandle?
    private var received = 0
    private var magic = Data()

    init(directory: URL, done: @escaping @Sendable (ImageAttacher.Attachment?) -> Void) {
        self.directory = directory
        self.done = done
        self.partial = directory.appendingPathComponent(UUID().uuidString)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= ImageAttacher.maxBytes
        else { return completionHandler(.cancel) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { return completionHandler(.cancel) }
            file = try FileHandle(forWritingTo: partial)
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= ImageAttacher.maxBytes, let file else { return dataTask.cancel() }
        if magic.count < 8 { magic.append(data.prefix(8 - magic.count)) }
        do {
            try file.write(contentsOf: data)
        } catch {
            dataTask.cancel()
        }
    }

    /// Refuses a redirect away from https.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? file?.close()
        done(error == nil ? attachment() : nil)
        try? FileManager.default.removeItem(at: partial)
    }

    /// Renames the download with its type's extension and attaches it; deletes it if that fails.
    private func attachment() -> ImageAttacher.Attachment? {
        guard file != nil, let type = ImageAttacher.ImageType(magic: magic) else { return nil }
        let image = partial.appendingPathExtension(type.fileExtension)
        do {
            try FileManager.default.moveItem(at: partial, to: image)
            return ImageAttacher.Attachment(value: try UNNotificationAttachment(identifier: "pushwren-image", url: image, options: nil))
        } catch {
            try? FileManager.default.removeItem(at: image)
            return nil
        }
    }
}
