import OpenEyeCore
import SwiftUI

@main
struct OpenEyeIOSApp: App {
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(OpenEyeCore.appName)
                    .font(.title)
                Text("iPhone du parent")
            }
        }
    }
}
