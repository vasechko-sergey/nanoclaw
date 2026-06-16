import Foundation

/// Single source of truth for the NanoClaw server endpoint.
///
/// The server URL is fixed — `jarvis.vasechko.dev` is a stable domain fronting the
/// VDS via nginx + TLS, so the *domain* is the indirection layer. There is nothing
/// for the user to configure, so the URL is baked in rather than stored/edited.
/// To repoint the app at a different server, change this one line and rebuild.
///
/// Value is a `wss://` URL: `WebSocketClientV2` uses it as-is for the socket;
/// the REST services (`StateService`, `HealthRequests`, `HealthUpload`) normalize
/// `wss://` → `https://` for their HTTP calls.
enum ServerConfig {
    static let url = "wss://jarvis.vasechko.dev"
}
