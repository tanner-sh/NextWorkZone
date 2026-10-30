import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// 选择要上传的文件（系统的打开面板，附着在当前窗口上）。
    func filePicker(isPresented: Binding<Bool>, multiple: Bool = true, onPick: @escaping ([String]) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.item], allowsMultipleSelection: multiple) { result in
            if case .success(let urls) = result, !urls.isEmpty { onPick(urls.map(\.path)) }
        }
    }

    /// 选择文件夹（可以新建）。
    func folderPicker(isPresented: Binding<Bool>, onPick: @escaping (String) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { onPick(url.path) }
        }
    }

    /// 把下载好的内容存到用户选择的位置（系统的存储面板），存好后用默认应用打开。
    func fileSaver(_ file: Binding<ExportedFile?>) -> some View {
        fileExporter(isPresented: Binding(get: { file.wrappedValue != nil }, set: { if !$0 { file.wrappedValue = nil } }),
                     document: file.wrappedValue.map { DataDocument(data: $0.data) },
                     contentType: file.wrappedValue?.type ?? .data,
                     defaultFilename: file.wrappedValue?.filename) { result in
            switch result {
            case .success(let url):
                toast("已保存到 \(url.path)")
                NSWorkspace.shared.open(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { toast("保存失败：\(errorMessage(error))", error: true) }
            }
        }
    }
}

/// 等待保存的文件内容。
struct ExportedFile {
    var data: Data
    var filename: String
    var type: UTType
}

/// 存储面板要的文档：只是一段数据。
struct DataDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
