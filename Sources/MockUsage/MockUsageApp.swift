import SwiftUI
#if SWIFT_PACKAGE
import UsageCore
#endif

@main
struct MockUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore.shared
    var body: some Scene {
        Window("Mock Usage", id: "main") {
            MainView(compact: false).environmentObject(store).onAppear { store.start() }
        }.defaultSize(width: 620, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { store.changeZoom(0.1) }.keyboardShortcut("+", modifiers: .command)
                Button("Zoom In") { store.changeZoom(0.1) }.keyboardShortcut("=", modifiers: .command).hidden()
                Button("Zoom Out") { store.changeZoom(-0.1) }.keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { store.resetZoom() }.keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
