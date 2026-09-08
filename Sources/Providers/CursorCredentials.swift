import Foundation
import SQLite3

/// The session Cursor keeps for itself, borrowed rather than minted — the same
/// bargain as Claude Code's keychain token: Cursor mints and refreshes it, we
/// read the current value.
///
/// Two Cursor installations store it differently:
///
/// - The **editor** (a VS Code fork) keeps it in a SQLite global-state store,
///   alongside the email and plan it caches for its own UI.
/// - The **CLI** (`cursor`) keeps the token in the login keychain and the user
///   ID in `~/.cursor/cli-config.json`, and never touches the SQLite store.
///
/// Both produce the same cookie — `WorkosCursorSessionToken=<accountID>::<token>`
/// — and both hit the same endpoint. The IDE path is tried first; the CLI is
/// the fallback for someone who has the agent but not the editor.
struct CursorCredentials {
    let accountID: String
    let accessToken: String
    /// The web API wants the pair as one cookie.
    var sessionCookie: String { "WorkosCursorSessionToken=\(accountID)::\(accessToken)" }

    static var storeURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// The CLI's configuration directory, where `cli-config.json` holds the user
    /// ID and email the keychain token does not.
    static var cliConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cursor/cli-config.json")
    }

    /// Keychain entries the Cursor CLI files under, matching what `cursor login`
    /// writes. The token is a JWT; the user ID it pairs with lives in
    /// `cli-config.json`, not the keychain.
    static let cliTokenService = "cursor-access-token"
    static let cliTokenAccount = "cursor-user"

    /// Minted by ToDesktop, who build Cursor — stable across updates, but not
    /// across Cursor leaving ToDesktop or rebranding. Kept here beside the store
    /// path so the two facts about a Cursor installation change together: the
    /// activity monitor and the sign-in route both read this one.
    static let bundleID = "com.todesktop.230313mzl4w4u92"

    /// Identity, read from the same store as the session. Non-secret: the email
    /// and plan the editor caches for its own UI.
    ///
    /// Falls back to the CLI's `cli-config.json` when the editor is not
    /// installed — the CLI caches `authInfo.email` there but not a plan name.
    static func account(from url: URL = storeURL, cliConfig: URL = cliConfigURL) -> ProviderAccount? {
        if let account = editorAccount(from: url) { return account }
        return cliAccount(from: cliConfig)
    }

    private static func editorAccount(from url: URL) -> ProviderAccount? {
        guard let db = SQLiteStore.open(url) else { return nil }
        defer { sqlite3_close(db) }
        func value(_ key: String) -> String? {
            SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
        }
        guard let email = value("cursorAuth/cachedEmail"), !email.isEmpty else { return nil }
        return ProviderAccount(
            label: email,
            plan: value("cursorAuth/stripeMembershipType"),
            source: "Cursor",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }

    private static func cliAccount(from url: URL) -> ProviderAccount? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["authInfo"] as? [String: Any],
              let email = auth["email"] as? String, !email.isEmpty
        else { return nil }
        return ProviderAccount(
            label: email,
            plan: nil,
            source: "Cursor",
            manageURL: URL(string: "https://cursor.com/dashboard")
        )
    }

    /// Loads the session, trying the editor's SQLite store first and falling
    /// back to the CLI's keychain token + `cli-config.json` user ID.
    ///
    /// `cliTokenService`/`cliTokenAccount` are overridable so tests can point
    /// at a service name that does not exist in the keychain, rather than at
    /// the real one a machine with the CLI installed does have.
    static func load(
        from url: URL = storeURL,
        cliConfig: URL = cliConfigURL,
        cliTokenService: String = cliTokenService,
        cliTokenAccount: String = cliTokenAccount
    ) throws -> CursorCredentials {
        if FileManager.default.fileExists(atPath: url.path) {
            if let credentials = try? loadFromEditor(from: url) { return credentials }
        }
        return try loadFromCLI(
            cliConfig: cliConfig, tokenService: cliTokenService, tokenAccount: cliTokenAccount
        )
    }

    /// The editor's session, read from its SQLite global-state store.
    ///
    // Read-only, but *not* `immutable`. Cursor runs the database in WAL
    // mode, and `immutable=1` tells SQLite to ignore the write-ahead log —
    // so it happily returns whatever was true at the last checkpoint. That
    // is how you end up serving a token the editor has already rotated.
    private static func loadFromEditor(from url: URL) throws -> CursorCredentials {
        guard let db = SQLiteStore.open(url) else { throw UsageProviderError.needsAuth }
        defer { sqlite3_close(db) }

        guard let token = value(forKey: "cursorAuth/accessToken", in: db),
              let account = value(forKey: "cursorAuth/stripeMembershipAuthId", in: db),
              !token.isEmpty, !account.isEmpty
        else { throw UsageProviderError.needsAuth }

        return CursorCredentials(accountID: account, accessToken: token)
    }

    /// The CLI's session: a JWT in the login keychain paired with the user ID
    /// from `cli-config.json`. The keychain holds no account ID — the config
    /// file is the only place the CLI writes one.
    private static func loadFromCLI(
        cliConfig: URL, tokenService: String, tokenAccount: String
    ) throws -> CursorCredentials {
        guard let token = cliAccessToken(service: tokenService, account: tokenAccount) else {
            throw UsageProviderError.needsAuth
        }
        guard let userID = cliUserID(from: cliConfig) else { throw UsageProviderError.needsAuth }
        return CursorCredentials(accountID: userID, accessToken: token)
    }

    /// Reads the newest `cursor-access-token` from the login keychain. The CLI
    /// may file several across logins; the newest is the current one.
    private static func cliAccessToken(service: String, account: String) -> String? {
        guard let match = KeychainItem.newest(service: service, account: account) else {
            return nil
        }
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecValuePersistentRef: match.persistentRef,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The numeric user ID the CLI stores in `cli-config.json` under
    /// `authInfo.userId`. The cookie needs it; the keychain does not hold it.
    private static func cliUserID(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["authInfo"] as? [String: Any]
        else { return nil }
        if let id = auth["userId"] as? Int { return String(id) }
        return auth["userId"] as? String
    }

    private static func value(forKey key: String, in db: OpaquePointer?) -> String? {
        SQLiteStore.rows(in: db, sql: "SELECT value FROM ItemTable WHERE key = ?", bind: key).first
    }
}

