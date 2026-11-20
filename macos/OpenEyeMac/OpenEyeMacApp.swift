import OpenEyeCore
import SwiftUI

@main
struct OpenEyeMacApp: App {
    var body: some Scene {
        WindowGroup {
            VStack {
                Text(OpenEyeCore.appName)
                    .font(.title)
                Text("Mac supervisé")
            }
            .padding()
        }
    }
}
