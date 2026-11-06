#if os(macOS)
import SwiftUI

/// DEBUG launch arguments of the «История» window (UI checks with `Tools/ui-shot.sh`):
///   --demo-history-videos            sample trainings with generated videos and two recordings without a training
///                                    (kept in tmp/WaitingPawsHistoryDemo, never in the real or the shared preview history)
///   --history-empty                  no trainings and no recordings (the empty state)
///   --history-appearance light|dark  force the appearance of this window
///   --history-select <n>             select the n-th row of the table (0 = the top one)
///   --history-scope trainings|clips  segmented control
///   --history-search <text>          search field
///   --history-period fourWeeks|threeMonths|all  chart period (shown, not kept)
///   --history-prompt delete|delete-all  open that confirmation
///   --history-inspector-bottom       inspector scrolled to its end
///   --history-seek <seconds>         move the playhead of the selected video
///   --history-no-inspector           inspector closed (the search field next to the buttons)
///   --history-toggle-inspector <s>   open / close the inspector after that many seconds (the search field moving)
enum MacHistoryDebug {
    static var colorScheme: ColorScheme? {
        #if DEBUG
        switch value("--history-appearance") {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
        #else
        return nil
        #endif
    }

    static var seek: TimeInterval? {
        #if DEBUG
        return value("--history-seek").flatMap(Double.init)
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// `--history-inspector-bottom`: the inspector opens scrolled to its end.
    static var inspectorAnchor: UnitPoint? {
        CommandLine.arguments.contains("--history-inspector-bottom") ? .bottom : nil
    }

    static func value(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func setUp(_ controller: MacHistoryController, model: AppModel) async {
        if let scope = value("--history-scope").flatMap(MacHistoryController.Scope.init(rawValue:)) { controller.scope = scope }
        if let period = value("--history-period").flatMap(MacHistoryPeriod.init(rawValue:)) { controller.period = period }
        if let search = value("--history-search") { controller.search = search }
        if CommandLine.arguments.contains("--history-empty") {
            controller.demo = MacHistoryDemo(records: [], clips: [], folder: FileManager.default.temporaryDirectory)
        } else if CommandLine.arguments.contains("--demo-history-videos") {
            controller.demo = await MacHistoryDemo.make()
            await controller.refreshFiles(model)
        }
        if let index = value("--history-select").flatMap(Int.init) {
            let rows = controller.visibleRows(model)
            if rows.indices.contains(index) { controller.selection = rows[index].id }
        }
        if CommandLine.arguments.contains("--history-no-inspector") { controller.showsInspector = false }
        if let delay = value("--history-toggle-inspector").flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                controller.showsInspector.toggle()
            }
        }
        switch value("--history-prompt") {
        case "delete":
            try? await Task.sleep(for: .milliseconds(500))
            if let row = controller.row(controller.selection, model: model) { controller.confirmDelete(row) }
        case "delete-all":
            controller.confirmDeleteAll = true
        default:
            break
        }
    }
    #endif
}
#endif
