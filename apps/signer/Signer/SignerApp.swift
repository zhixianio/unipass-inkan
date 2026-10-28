import SwiftUI

@main
struct SignerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .task { await model.watchNetwork() }
                #if DEBUG
                .task {
                    // 截图 / 演示：`-demoScenario red` 之类的启动参数。
                    if let s = UserDefaults.standard.string(forKey: "demoScenario"), let d = DemoScenario(rawValue: s) {
                        model.load(demo: d)
                    }
                }
                #endif
        }
    }
}
