import Foundation
import UserNotifications

/// A Notification Service Extension that attaches a push's image and confirms its delivery to
/// Pushwren. Make your extension's principal class a subclass:
///
///     class NotificationService: PushwrenNotificationService {}
///
/// A push with neither an image nor a receipt code is delivered as it came. Subclasses may override
/// both methods (calling `super`) to change the content further.
open class PushwrenNotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handle: PushwrenExtension.Handle?
    var configuration = PushwrenExtension.Configuration.live

    open override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let handle = PushwrenExtension.handle(request, contentHandler: contentHandler, configuration: configuration)
        lock.withLock { self.handle = handle }
    }

    /// iOS calls this, on another thread, when the extension's time is nearly up.
    open override func serviceExtensionTimeWillExpire() {
        lock.withLock { handle }?.timeWillExpire()
    }
}

/// For an app with its own Notification Service Extension: call `handle` from `didReceive`, and the
/// returned handle's `timeWillExpire()` from `serviceExtensionTimeWillExpire()`.
public enum PushwrenExtension {
    /// Posts the push's delivery receipt (`_r`) and downloads its image (`_i`) at the same time,
    /// then calls `contentHandler` once with the content, the image attached if it arrived. The
    /// notification waits for the image, but never more than 1 second for the receipt: the receipt
    /// request is left running when the wait ends, and may or may not finish before iOS suspends the
    /// extension. A push with neither is passed to `contentHandler` at once, untouched.
    public static func handle(
        _ request: UNNotificationRequest,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) -> Handle {
        handle(request, contentHandler: contentHandler, configuration: .live)
    }

    static func handle(
        _ request: UNNotificationRequest,
        contentHandler: @escaping (UNNotificationContent) -> Void,
        configuration: Configuration
    ) -> Handle {
        let userInfo = request.content.userInfo
        let poster = ReceiptPoster(session: configuration.session, localBaseURL: configuration.localReceiptBaseURL)
        let receipt = poster.request(for: userInfo)
        let image = ImageAttacher.imageURL(in: userInfo)

        let handle = Handle(content: request.content, contentHandler: contentHandler, receiptPending: receipt != nil, imagePending: image != nil)
        if let receipt {
            poster.post(receipt) { handle.receiptFinished() }
            DispatchQueue.global().asyncAfter(deadline: .now() + configuration.receiptWait) { handle.receiptWaitOver() }
        }
        if let image {
            let task = ImageAttacher(session: configuration.session, directory: configuration.directory).start(image) { attachment in
                handle.imageFinished(attachment)
            }
            handle.imageTask(task)
        }
        handle.deliverIfDone()
        return handle
    }

    /// One push's work in progress.
    public final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private let content: UNNotificationContent
        private var contentHandler: ((UNNotificationContent) -> Void)?
        private var receiptPending: Bool
        private var imagePending: Bool
        private var attachment: UNNotificationAttachment?
        private var task: URLSessionTask?

        init(content: UNNotificationContent, contentHandler: @escaping (UNNotificationContent) -> Void, receiptPending: Bool, imagePending: Bool) {
            self.content = content
            self.contentHandler = contentHandler
            self.receiptPending = receiptPending
            self.imagePending = imagePending
        }

        /// Delivers what's ready now: the content, with the image only if it has arrived. Later
        /// results are dropped; the content handler is never called twice.
        public func timeWillExpire() {
            deliver()
            lock.withLock { task }?.cancel()
        }

        func imageTask(_ task: URLSessionTask) {
            lock.withLock { self.task = task }
        }

        /// The receipt request has finished, whatever its outcome.
        func receiptFinished() {
            lock.withLock { receiptPending = false }
            deliverIfDone()
        }

        /// The receipt's wait is over; it is no longer waited for (its request keeps running).
        func receiptWaitOver() {
            receiptFinished()
        }

        /// The image has finished: its attachment, or nil if it failed.
        func imageFinished(_ image: ImageAttacher.Attachment?) {
            let late = lock.withLock {
                imagePending = false
                if contentHandler == nil { return image }
                if let image { attachment = image.value }
                return nil
            }
            // Delivered without it: the system won't move the file, so delete it.
            if let late { try? FileManager.default.removeItem(at: late.value.url) }
            deliverIfDone()
        }

        func deliverIfDone() {
            if lock.withLock({ !imagePending && !receiptPending }) { deliver() }
        }

        private func deliver() {
            let (handler, attachment) = lock.withLock {
                defer { contentHandler = nil }
                return (contentHandler, attachment)
            }
            guard let handler else { return }
            guard let attachment, let mutable = content.mutableCopy() as? UNMutableNotificationContent else {
                return handler(content)
            }
            mutable.attachments = content.attachments + [attachment]
            handler(mutable)
        }
    }

    /// What the helper talks to. Tests swap in stubs.
    struct Configuration: Sendable {
        let session: URLSession
        let localReceiptBaseURL: URL?
        let directory: URL
        /// The longest the notification waits for its receipt request.
        var receiptWait: TimeInterval = 1

        static let live = Configuration(
            session: {
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil
                return URLSession(configuration: config)
            }(),
            localReceiptBaseURL: nil,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("com.pushwren.notification-service", isDirectory: true)
        )
    }
}
