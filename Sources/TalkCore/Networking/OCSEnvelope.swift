import Foundation

struct OCSMeta: Decodable, Sendable, Equatable {
    let status: String
    let statuscode: Int
    let message: String?

    /// `/ocs/v2.php` mirrors HTTP semantics (200/201/…); `/ocs/v1.php` uses 100 for success.
    /// We only ever call v2, but accepting 100 means a mis-built v1 URL fails loudly at the
    /// HTTP layer rather than silently looking like an OCS error.
    var isSuccess: Bool {
        statuscode == 100 || (200...299).contains(statuscode)
    }
}

/// The OCS envelope: `{"ocs": {"meta": {...}, "data": ...}}`.
///
/// `data` is optional because Nextcloud answers "nothing here" with an **empty array**
/// even on endpoints whose success shape is an object (`lastMessage`, `messageParameters`,
/// `reactions`, and several OCS responses). Decoding that as the expected type fails, so
/// the empty-array case is recognized explicitly — and a genuine schema mismatch still
/// rethrows the original error instead of being swallowed as "empty".
struct OCSEnvelope<T: Decodable & Sendable>: Decodable, Sendable {
    let meta: OCSMeta
    let data: T?

    private enum RootKey: String, CodingKey { case ocs }
    private enum InnerKey: String, CodingKey { case meta, data }

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        let inner = try root.nestedContainer(keyedBy: InnerKey.self, forKey: .ocs)
        meta = try inner.decode(OCSMeta.self, forKey: .meta)

        guard inner.contains(.data), try !inner.decodeNil(forKey: .data) else {
            data = nil
            return
        }
        do {
            data = try inner.decode(T.self, forKey: .data)
        } catch {
            if let empty = try? inner.decode([String].self, forKey: .data), empty.isEmpty {
                data = nil
            } else {
                throw error
            }
        }
    }
}

/// A decoded OCS response plus the headers we care about (`X-Chat-Last-Given`,
/// `X-Nextcloud-Talk-Hash`, …), which carry real protocol state and must not be dropped.
struct OCSResponse<T: Sendable>: Sendable {
    let value: T
    let status: Int
    let headers: HTTPHeaders
}

extension OCSResponse {
    func map<U: Sendable>(_ transform: (T) throws -> U) rethrows -> OCSResponse<U> {
        OCSResponse<U>(value: try transform(value), status: status, headers: headers)
    }
}
