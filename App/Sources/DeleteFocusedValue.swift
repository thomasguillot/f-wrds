import SwiftUI

/// The scene-wide "delete whatever is selected" action, published by whichever pane currently has a
/// deletable selection and read once, centrally, by the ⌘⌫ menu command. See `MainWindowView`.
struct DeleteActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deleteAction: (() -> Void)? {
        get { self[DeleteActionKey.self] }
        set { self[DeleteActionKey.self] = newValue }
    }
}
