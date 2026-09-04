import Foundation

extension Notification.Name {
    /// Posted by the Hooks settings pane when the user turns hook tracking on
    /// or off, carrying the new value. Whether hooks are enabled is read
    /// straight from the settings repository and has no observable property, so
    /// this is what tells the rest of the app to catch up.
    static let hookSettingsChanged = Notification.Name("com.tddworks.claudebar.hookSettingsChanged")
}
