#if DEBUG
import CoordinatorFlow
import SwiftUI

// 开发者菜单和窗口（只在 DEBUG 构建、并且带启动参数 `-InkanDeveloper YES` 时出现）：
// 扫码测试、动态二维码、交易服务这几个调试页，以及没有手机时的模拟配对。

enum DeveloperPage: String, CaseIterable, Identifiable {
    case scan, display, sts

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .scan: "Scan Test"
        case .display: "Animated QR"
        case .sts: "Transaction Service (STS)"
        }
    }

    var symbol: String {
        switch self {
        case .scan: "camera.viewfinder"
        case .display: "qrcode"
        case .sts: "network"
        }
    }
}

@Observable
final class DeveloperState {
    var page: DeveloperPage = .scan
}

struct DeveloperCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if app.developerMode {
            CommandMenu("Developer") {
                ForEach(DeveloperPage.allCases) { page in
                    Button(page.title) {
                        app.developer.page = page
                        openWindow(id: DeveloperWindow.id)
                    }
                }
                Divider()
                Button("Simulate Pairing with the Test-Vector Signer") {
                    _ = try? app.pair(PairedSigner(PairSignerView.testVectorPairing, verifiedOnChain: false))
                }
                Button("Show the Welcome Flow Again") { app.onboarded = false }
            }
        }
    }
}

struct DeveloperWindow: View {
    static let id = "developer"
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var developer = app.developer
        NavigationSplitView {
            List(selection: Binding<DeveloperPage?>(get: { developer.page }, set: { if let p = $0 { developer.page = p } })) {
                ForEach(DeveloperPage.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            switch developer.page {
            case .scan: ScanScreen()
            case .display: AnimatedQRScreen()
            case .sts: STSScreen()
            }
        }
    }
}
#endif
