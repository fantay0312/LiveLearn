import AppKit
import UniformTypeIdentifiers
import SessionStorage

/// Save-panel flow for one record. Rendering happens before the panel opens, so an empty
/// session is refused with a message instead of producing an empty file.
@MainActor
enum ExportPanel {
    static func present(_ record: SessionRecord, format: ExportFormat, model: AppModel) {
        let rendered: (text: String, fileName: String)
        do {
            rendered = try model.exportText(record, format: format)
        } catch {
            model.noteExport(result: "无法导出：\(error)")
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 \(format.label)"
        panel.nameFieldStringValue = rendered.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try Data(rendered.text.utf8).write(to: url, options: .atomic)
            model.noteExport(result: "已导出到 \(url.lastPathComponent)")
        } catch {
            model.noteExport(result: "导出失败：\(error.localizedDescription)")
        }
    }
}
