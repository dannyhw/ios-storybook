import SwiftUI
import StorybookUI

// Stories in linked modules (here SampleDesignSystem) are discovered at
// runtime; nothing to register.
@main
struct StorybookHostApp: App {
    var body: some Scene {
        StorybookScene()
    }
}
