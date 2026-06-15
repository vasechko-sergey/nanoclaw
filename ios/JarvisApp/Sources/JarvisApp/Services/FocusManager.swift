import Intents

/// Reads the system Focus status. The API only exposes whether the user is in
/// SOME Focus (`isFocused`), NOT which one — knowing the specific mode requires a
/// Focus-filter App Intent, which is out of scope.
struct FocusManager {
    func isFocused() async -> Bool? {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus != .authorized {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                center.requestAuthorization { _ in cont.resume() }
            }
        }
        guard center.authorizationStatus == .authorized else { return nil }
        return center.focusStatus.isFocused
    }
}
