import AppKit
import SwiftUI


struct AIDMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("AI 剧本杀", id: "main") {
            MainView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1360, height: 860)
        .commands { AppCommands(model: model) }

        Window("大屏", id: "stage") {
            StageView()
                .environment(model)
                .environmentObject(model.narrator)
                .preferredColorScheme(.dark)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.hiddenTitleBar)

        Window("导入扫描剧本", id: "import") {
            ImportView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 1000, height: 720)

        WindowGroup("编辑剧本", id: "editor", for: URL.self) { $folder in
            if let folder {
                ScriptEditorView(folder: folder)
                    .environment(model)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 980, minHeight: 640)
            }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environment(model)
                .environmentObject(model.narrator)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("导入扫描剧本…") { openWindow(id: "import") }.keyboardShortcut("i")
            Button("打开剧本文件夹…") { pickFolder(model) }.keyboardShortcut("o")
            Divider()
            Button("在 Finder 中显示我的剧本") { NSWorkspace.shared.open(Paths.scripts) }
        }
        CommandMenu("游戏") {
            Button("下一阶段") { model.session?.game.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command).disabled(model.session == nil)
            Button("上一阶段") { model.session?.game.prev() }
                .keyboardShortcut(.leftArrow, modifiers: .command).disabled(model.session == nil)
            Button("重播本阶段旁白") { model.session?.game.startNarration() }
                .keyboardShortcut("r").disabled(model.session == nil)
            Divider()
            Button("打开大屏") { openWindow(id: "stage") }.keyboardShortcut("b").disabled(model.session == nil)
            Divider()
            Button("结束游戏") { model.endGame() }.disabled(model.session == nil)
        }
    }
}

@MainActor
func pickFolder(_ model: AppModel) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = true
    p.allowedContentTypes = [.init(filenameExtension: "yaml")!]
    p.message = "选择剧本文件夹（里面要有 script.yaml）"
    p.prompt = "添加到剧本库"
    if p.runModal() == .OK, let u = p.url { model.addFolder(u) }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if let s = model.session {
                ConsoleView(session: s)
            } else {
                LibraryView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.session == nil)
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .task {
            // 测试用：--autostart [剧本文件夹] 启动后直接开一局新游戏
            let args = CommandLine.arguments
            // --import-live2d <模型文件夹>：导入 Live2D 模型并设为 DM 形象
            if let j = args.firstIndex(of: "--import-live2d"), args.indices.contains(j + 1) {
                model.importAvatar(URL(fileURLWithPath: args[j + 1]))
            }
            // --edit <剧本文件夹>：打开剧本编辑器
            if let j = args.firstIndex(of: "--edit"), args.indices.contains(j + 1) {
                openWindow(id: "editor", value: URL(fileURLWithPath: args[j + 1]))
            }
            guard let i = args.firstIndex(of: "--autostart") else { return }
            let folder = args.indices.contains(i + 1) ? URL(fileURLWithPath: args[i + 1]) : Paths.demo
            await model.start(model.entry(for: folder, builtIn: folder == Paths.demo), newGame: true)
        }
    }
}
