// A stand-in for UserNotifications.
@_exported import Foundation

public final class UNMutableNotificationContent: @unchecked Sendable {
    public init() {}
    public var title: String = ""
    public var subtitle: String = ""
    public var body: String = ""
    public var sound: UNNotificationSound?
    public var userInfo: [AnyHashable: Any] = [:]
    public var threadIdentifier: String = ""
    public var categoryIdentifier: String = ""
    public var interruptionLevel: UNNotificationInterruptionLevel = .active
    public var badge: NSNumber?
}

public struct UNNotificationSound: Sendable {
    public static let `default` = UNNotificationSound()
}

public enum UNNotificationInterruptionLevel: Sendable {
    case passive, active, timeSensitive, critical
}

public struct UNAuthorizationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let alert = UNAuthorizationOptions(rawValue: 1)
    public static let sound = UNAuthorizationOptions(rawValue: 2)
    public static let badge = UNAuthorizationOptions(rawValue: 4)
}

public struct UNNotificationPresentationOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let banner = UNNotificationPresentationOptions(rawValue: 1)
    public static let sound = UNNotificationPresentationOptions(rawValue: 2)
    public static let badge = UNNotificationPresentationOptions(rawValue: 4)
    public static let list = UNNotificationPresentationOptions(rawValue: 8)
}

public final class UNNotificationRequest: @unchecked Sendable {
    public let identifier: String
    public let content: UNMutableNotificationContent
    public init(identifier: String, content: UNMutableNotificationContent, trigger: Any?) {
        self.identifier = identifier
        self.content = content
    }
}

public final class UNNotification: @unchecked Sendable {
    public let request: UNNotificationRequest
    public init(request: UNNotificationRequest) { self.request = request }
}

public final class UNNotificationResponse: @unchecked Sendable {
    public let notification: UNNotification
    public init(notification: UNNotification) { self.notification = notification }
}

public final class UNUserNotificationCenter: @unchecked Sendable {
    public static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    public weak var delegate: (any UNUserNotificationCenterDelegate)?
    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    public func add(_ request: UNNotificationRequest, withCompletionHandler handler: (((any Error)?) -> Void)? = nil) {}
    public func getDeliveredNotifications(completionHandler: @escaping ([UNNotification]) -> Void) {}
    public func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    public func removeAllDeliveredNotifications() {}
}

public protocol UNUserNotificationCenterDelegate: NSObjectProtocol {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
}

extension UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {}
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
}
