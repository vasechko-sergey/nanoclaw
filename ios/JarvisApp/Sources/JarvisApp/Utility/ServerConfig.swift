import Foundation

/// Single source of truth for the NanoClaw server endpoint.
///
/// The server URL is fixed — `jarvis.vasechko.dev` is a stable domain fronting the
/// VDS via nginx + TLS, so the *domain* is the indirection layer. There is nothing
/// for the user to configure, so the URL is baked in rather than stored/edited.
/// To repoint the app at a different server, change this one line and rebuild.
///
/// Value is a `wss://` URL: `WebSocketClientV2` uses it as-is for the socket;
/// the REST services normalize `wss://` → `https://` via `httpBase(from:)` /
/// `httpURL(path:)` for their HTTP calls.
enum ServerConfig {
    static let url = "wss://jarvis.vasechko.dev"

    /// Normalize a ws/host server string to an `https://`/`http://` base for REST calls:
    /// `wss://` → `https://`, `ws://` → `http://`, a bare host gets an `http://` prefix,
    /// an already-`http(s)` string is left untouched. Single source of truth for the
    /// ws→http rewrite shared by every REST service. Defaults to `ServerConfig.url`;
    /// `ImageFetcher` passes its injected server string so the rewrite stays testable.
    static func httpBase(from server: String = url) -> String {
        var base = server
        if base.hasPrefix("wss://") { base = "https://" + base.dropFirst(6) }
        else if base.hasPrefix("ws://") { base = "http://" + base.dropFirst(5) }
        else if !base.hasPrefix("http") { base = "http://" + base }
        return base
    }

    /// `httpBase()` joined with a leading-slash-free `path` (e.g. `"ios/pending"`),
    /// inserting a single `/` unless the base already ends in one. `nil` if the
    /// resulting string isn't a valid URL.
    static func httpURL(path: String) -> URL? {
        let base = httpBase()
        return URL(string: base.hasSuffix("/") ? base + path : base + "/" + path)
    }
}
