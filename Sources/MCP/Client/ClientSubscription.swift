extension Client {
    /// A state change or notification delivered for a long-lived subscription.
    public enum SubscriptionEvent: Hashable, Sendable {
        /// The server established or re-established the subscription.
        case acknowledged(SubscriptionFilter)
        /// A notification selected by the acknowledged filter.
        case notification(SubscriptionNotification)
        /// The underlying stream ended without a graceful response.
        case disconnected
    }

    /// An established long-lived notification subscription.
    public struct Subscription: Sendable {
        /// The JSON-RPC ID used to identify this subscription on every connection.
        public let id: ID
        /// The notification types requested by the client.
        public let requestedNotifications: SubscriptionFilter
        /// The notification types accepted when the subscription was first established.
        public let acknowledgedNotifications: SubscriptionFilter
        /// Acknowledgments, notifications, and unexpected stream closures.
        public let events: AsyncThrowingStream<SubscriptionEvent, Swift.Error>

        package init(
            id: ID,
            requestedNotifications: SubscriptionFilter,
            acknowledgedNotifications: SubscriptionFilter,
            events: AsyncThrowingStream<SubscriptionEvent, Swift.Error>
        ) {
            self.id = id
            self.requestedNotifications = requestedNotifications
            self.acknowledgedNotifications = acknowledgedNotifications
            self.events = events
        }
    }
}
