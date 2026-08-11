package protocol ResponseCacheClock: Sendable {
    func now() async -> Duration
}

package struct ContinuousResponseCacheClock: ResponseCacheClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    package init() {
        origin = clock.now
    }

    package func now() -> Duration {
        origin.duration(to: clock.now)
    }
}

package struct ResponseCacheRequestKey: Hashable, Sendable {
    let connectionGeneration: Int
    let method: String
    let parameters: Value
}

private enum ResponseCachePartition: Hashable {
    case `public`
    case `private`(String)
}

private struct ResponseCacheStorageKey: Hashable {
    let request: ResponseCacheRequestKey
    let partition: ResponseCachePartition
}

private struct ResponseCacheEntry {
    let result: Value
    let receivedAt: Duration
    let ttlMs: Int
    var lastAccess: UInt64
}

private struct ResponseCacheListScopeKey: Hashable {
    let connectionGeneration: Int
    let method: String
    let partition: ResponseCacheListPartition
    let cursor: String
}

private enum ResponseCacheListPartition: Hashable {
    case `public`
    case `private`(ResponseCacheAuthorizationContext)
}

package struct ResponseCacheStorage {
    private var entries: [ResponseCacheStorageKey: ResponseCacheEntry] = [:]
    private var listScopes: [ResponseCacheListScopeKey: CacheScope] = [:]
    private var accessCounter: UInt64 = 0

    package var count: Int { entries.count }

    package mutating func value(
        for request: ResponseCacheRequestKey,
        authorizationContext: ResponseCacheAuthorizationContext,
        now: Duration
    ) -> Value? {
        if let value = value(
            for: ResponseCacheStorageKey(request: request, partition: .public),
            now: now
        ) {
            return value
        }
        guard case .known(let context) = authorizationContext else { return nil }
        return value(
            for: ResponseCacheStorageKey(request: request, partition: .private(context)),
            now: now
        )
    }

    package mutating func store(
        _ result: Value,
        policy: CachePolicy,
        for request: ResponseCacheRequestKey,
        authorizationContext: ResponseCacheAuthorizationContext,
        now: Duration,
        maximumEntries: Int
    ) {
        guard policy.ttlMs > 0 else {
            removeEntries(for: request)
            return
        }

        let key: ResponseCacheStorageKey
        switch policy.cacheScope {
        case .public:
            removeEntries(for: request)
            key = ResponseCacheStorageKey(request: request, partition: .public)
        case .private:
            removePublicEntry(for: request)
            guard case .known(let context) = authorizationContext else { return }
            key = ResponseCacheStorageKey(request: request, partition: .private(context))
        }

        accessCounter &+= 1
        entries[key] = ResponseCacheEntry(
            result: result,
            receivedAt: now,
            ttlMs: policy.ttlMs,
            lastAccess: accessCounter
        )
        while entries.count > maximumEntries,
            let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        {
            entries.removeValue(forKey: oldest)
        }
    }

    package mutating func validateListScope(
        _ scope: CacheScope,
        request: ResponseCacheRequestKey,
        result: Value,
        authorizationContext: ResponseCacheAuthorizationContext
    ) throws {
        guard Self.listMethods.contains(request.method) else { return }
        if let cursor = request.parameters.objectValue?["cursor"]?.stringValue {
            let publicKey = ResponseCacheListScopeKey(
                connectionGeneration: request.connectionGeneration,
                method: request.method,
                partition: .public,
                cursor: cursor
            )
            let privateKey = ResponseCacheListScopeKey(
                connectionGeneration: request.connectionGeneration,
                method: request.method,
                partition: .private(authorizationContext),
                cursor: cursor
            )
            if let existing = listScopes[publicKey] ?? listScopes[privateKey], existing != scope {
                invalidate(
                    method: request.method,
                    connectionGeneration: request.connectionGeneration
                )
                throw MCPError.invalidRequest(
                    "All pages of \(request.method) must use the same cacheScope")
            }
        }
        if let nextCursor = result.objectValue?["nextCursor"]?.stringValue {
            listScopes[ResponseCacheListScopeKey(
                connectionGeneration: request.connectionGeneration,
                method: request.method,
                partition: scope == .public ? .public : .private(authorizationContext),
                cursor: nextCursor
            )] = scope
        }
    }

    package mutating func invalidate(
        method: String,
        connectionGeneration: Int,
        parameters: ((Value) -> Bool)? = nil
    ) {
        entries = entries.filter { key, _ in
            guard key.request.connectionGeneration == connectionGeneration,
                key.request.method == method
            else {
                return true
            }
            return !(parameters?(key.request.parameters) ?? true)
        }
        listScopes = listScopes.filter { key, _ in
            key.connectionGeneration != connectionGeneration || key.method != method
        }
    }

    package mutating func removeAll() {
        entries.removeAll()
        listScopes.removeAll()
    }

    private mutating func value(
        for key: ResponseCacheStorageKey,
        now: Duration
    ) -> Value? {
        guard var entry = entries[key] else { return nil }
        guard now < entry.receivedAt + .milliseconds(entry.ttlMs) else {
            entries.removeValue(forKey: key)
            return nil
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.result
    }

    private mutating func removeEntries(for request: ResponseCacheRequestKey) {
        entries = entries.filter { $0.key.request != request }
    }

    private mutating func removePublicEntry(for request: ResponseCacheRequestKey) {
        entries.removeValue(forKey: ResponseCacheStorageKey(
            request: request,
            partition: .public
        ))
    }

    private static let listMethods: Set<String> = [
        ListTools.name,
        ListPrompts.name,
        ListResources.name,
        ListResourceTemplates.name,
    ]
}
