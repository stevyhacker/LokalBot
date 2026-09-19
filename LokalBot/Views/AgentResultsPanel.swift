import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AgentResultsPanel: View {
    @ObservedObject var controller: AgentSessionController
    @Binding var selection: AgentResultPreview?
    @State private var exporting = false
    @State private var previewError: String?

    private var results: [AgentResultPreview] { controller.items.compactMap(AgentResultPreview.tool) }
    private var selected: AgentResultPreview? {
        guard let selection else { return results.last }
        return results.first(where: { $0.id == selection.id }) ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Results & sources").font(.headline).padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !controller.sourceAttachments.isEmpty {
                        Text("Sources used").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(controller.sourceAttachments) { source in
                            Button {
                                do { selection = try controller.contextResolver.resolve(source); previewError = nil } catch { previewError = error.localizedDescription }
                            } label: { Label(source.title, systemImage: source.icon).lineLimit(2) }
                            .buttonStyle(.borderless)
                        }
                    }
                    if !results.isEmpty {
                        Text("Activity results").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(results) { result in
                            Button { selection = result; previewError = nil } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.title).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(result.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8).background(selected?.id == result.id ? Brand.teal.opacity(0.12) : .clear,
                                                           in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }.frame(maxHeight: 200)
            Divider()
            if let previewError { Text(previewError).font(.callout).foregroundStyle(.orange).padding(16) }
            if let selected {
                HStack {
                    Text(selected.title).font(.headline).lineLimit(2)
                    Spacer()
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy result")
                    Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export result")
                }.buttonStyle(.borderless).padding(16)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(selected.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let original = selected.original, let proposed = selected.proposed {
                            change("Before", text: original, color: .red)
                            change("After", text: proposed, color: .green)
                        }
                        SelectableDigestText(selected.text, style: .agent)
                            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                        Text("Preview of recorded output or selected source. Opening a preview does not run a tool.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).padding(.bottom, 16)
                }
            } else {
                ContentUnavailableView("Your results will appear here", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Open a response, activity, or attached source to inspect it beside your task."))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.resultsPanel")
        .fileExporter(isPresented: $exporting, document: AgentPreviewDocument(text: selected?.text ?? ""),
                      contentType: .plainText, defaultFilename: "agent-result.txt") { result in
            if case .failure(let error) = result { previewError = error.localizedDescription }
        }
    }

    private func change(_ label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold))
            Text(text.isEmpty ? "(empty)" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentPreviewDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
