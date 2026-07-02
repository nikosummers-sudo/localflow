import Foundation
import ServiceManagement

/// Login-item registration via SMAppService, wrapped so launch-time reconciliation and
/// the Settings toggle share one code path. Defaults ON: a menu-bar dictation app is only
/// useful if it's already running, so a fresh install starts at login unless turned off.
enum LaunchAtLogin {
    static let defaultsKey = "launchAtLogin"

    /// The user's saved preference. Defaults to true when the key has never been set.
    static var isEnabledSetting: Bool {
        if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item to match `enabled`. Best-effort: returns
    /// false (rather than throwing) if the system refuses, so callers can revert quietly.
    @discardableResult
    static func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return true
        } catch {
            return false
        }
    }

    /// At launch, make the system login-item state match the saved setting.
    static func reconcile() {
        apply(isEnabledSetting)
    }
}
