// Stand-in for Combine. Only what the app touches: a publisher it can hand to onReceive.
@_exported import Foundation

public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
}

public struct NotificationCenterPublisher: Publisher {
    public typealias Output = Notification
    public typealias Failure = Never
    public init() {}
}

extension NotificationCenter {
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenterPublisher {
        NotificationCenterPublisher()
    }
}
