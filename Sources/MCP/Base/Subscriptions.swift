/// Notification types requested on a `subscriptions/listen` stream.
public struct SubscriptionFilter: Hashable, Codable, Sendable {
    public var toolsListChanged: Bool?
    public var promptsListChanged: Bool?
    public var resourcesListChanged: Bool?
    public var resourceSubscriptions: [String]?

    public init(
        toolsListChanged: Bool? = nil,
        promptsListChanged: Bool? = nil,
        resourcesListChanged: Bool? = nil,
        resourceSubscriptions: [String]? = nil
    ) {
        self.toolsListChanged = toolsListChanged
        self.promptsListChanged = promptsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
    }

    package func isSubset(of requested: SubscriptionFilter) -> Bool {
        if toolsListChanged == true, requested.toolsListChanged != true { return false }
        if promptsListChanged == true, requested.promptsListChanged != true { return false }
        if resourcesListChanged == true, requested.resourcesListChanged != true { return false }

        guard let resources = resourceSubscriptions else { return true }
        let requestedResources = Set(requested.resourceSubscriptions ?? [])
        return Set(resources).isSubset(of: requestedResources)
    }

    package func permits(method: String, parameters: Value) -> Bool {
        switch method {
        case ToolListChangedNotification.name:
            return toolsListChanged == true
        case PromptListChangedNotification.name:
            return promptsListChanged == true
        case ResourceListChangedNotification.name:
            return resourcesListChanged == true
        case ResourceUpdatedNotification.name:
            guard let uri = parameters.objectValue?["uri"]?.stringValue else { return false }
            return resourceSubscriptions?.contains(uri) == true
        default:
            return false
        }
    }
}

/// Opens a long-lived stream for explicitly selected server notifications.
public enum SubscriptionsListen: Method {
    public static let name = "subscriptions/listen"

    public struct Parameters: Hashable, Codable, Sendable {
        public var notifications: SubscriptionFilter
        public var _meta: Metadata?

        public init(
            notifications: SubscriptionFilter,
            _meta: Metadata? = nil
        ) {
            self.notifications = notifications
            self._meta = _meta
        }
    }

    public struct Result: Hashable, Codable, Sendable {
        public var resultType: ResultType
        public var _meta: Metadata

        public init(
            subscriptionID: ID,
            resultType: ResultType = .complete,
            _meta: Metadata = .init()
        ) {
            self.resultType = resultType
            var metadata = _meta
            metadata.subscriptionID = subscriptionID
            self._meta = metadata
        }
    }
}

/// Confirms the notification types accepted for a subscription stream.
public struct SubscriptionsAcknowledgedNotification: Notification {
    public static let name = "notifications/subscriptions/acknowledged"

    public struct Parameters: Hashable, Codable, Sendable {
        public var _meta: Metadata
        public var notifications: SubscriptionFilter

        public init(
            subscriptionID: ID,
            notifications: SubscriptionFilter,
            _meta: Metadata = .init()
        ) {
            var metadata = _meta
            metadata.subscriptionID = subscriptionID
            self._meta = metadata
            self.notifications = notifications
        }
    }
}

/// A notification correlated with one active subscription.
public struct SubscriptionNotification: Hashable, Sendable {
    public let subscriptionID: ID
    public let method: String
    public let parameters: Value

    public init(subscriptionID: ID, method: String, parameters: Value) {
        self.subscriptionID = subscriptionID
        self.method = method
        self.parameters = parameters
    }
}

package struct SubscriptionQueue<Element> {
    private var front: [Element] = []
    private var back: [Element] = []

    package var count: Int { front.count + back.count }
    package var isEmpty: Bool { front.isEmpty && back.isEmpty }

    package init(_ elements: [Element] = []) {
        back = elements
    }

    package mutating func append(_ element: Element) {
        back.append(element)
    }

    package mutating func popFirst() -> Element? {
        if front.isEmpty {
            front = back.reversed()
            back.removeAll(keepingCapacity: true)
        }
        return front.popLast()
    }

    package mutating func removeAll(
        where shouldRemove: (Element) throws -> Bool
    ) rethrows -> [Element] {
        var kept = SubscriptionQueue<Element>()
        var removed: [Element] = []
        while let element = popFirst() {
            if try shouldRemove(element) {
                removed.append(element)
            } else {
                kept.append(element)
            }
        }
        self = kept
        return removed
    }
}
