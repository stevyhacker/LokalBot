import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Beside the conversation: the files the task changed, its steps, the
/// sources it was given, and a preview of whichever one is chosen. Opening a
/// preview never runs a tool.
struct AgentResultsPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var controller: AgentSessionController
    let context: AgentStepWording.Context
    @Binding var selection: AgentResultPreview?
    let close: () -> Void
    @State private var exporting = false
    @State private var previewError: String?

    private var localized: (String) -> String { app.settings.appLanguage.catalog }
    private var steps: [AgentTranscriptItem] {
        controller.items.filter { if case .tool = $0 { true } else { false } }
    }
    private var results: [AgentResultPreview] { steps.compactMap(AgentResultPreview.tool) }
    private var changedFiles: [AgentChangedFile] { controller.changedFiles(in: steps) }
    private var selected: AgentResultPreview? {
        guard let selection else { return results.last }
        return results.first(where: { $0.id == selection.id }) ?? selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Results").font(.scaled(.headline)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("Close").accessibilityLabel("Close")
                    .accessibilityIdentifier("agent.results.close")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            if !controller.sourceAttachments.isEmpty || !steps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !changedFiles.isEmpty {
                            heading("Changed files")
                            ForEach(changedFiles) { file in fileRow(file) }
                        }
                        if !steps.isEmpty {
                            heading("Steps").padding(.top, changedFiles.isEmpty ? 0 : 8)
                            ForEach(steps) { step in stepRow(step) }
                        }
                        if !controller.sourceAttachments.isEmpty {
                            heading("Sources used").padding(.top, steps.isEmpty ? 0 : 8)
                            ForEach(controller.sourceAttachments) { source in
                                Button {
                                    do { selection = try controller.contextResolver.resolve(source); previewError = nil } catch { previewError = error.localizedDescription }
                                } label: { Label(source.title, systemImage: source.icon).lineLimit(2) }
                                .buttonStyle(.borderless)
                            }
                        }
                    }.padding(.horizontal, 16).padding(.bottom, 12)
                }.frame(maxHeight: 240)
                Divider()
            }
            if let previewError {
                Text(previewError).font(.scaled(.callout)).foregroundStyle(LBTokens.Palette.attentionText).padding(16)
            }
            if let selected {
                selectedPreview(selected)
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

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title).font(AppFont.scaled(.callout).weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func rowBackground(_ id: String) -> some ShapeStyle {
        selected?.id == id ? Brand.teal.opacity(0.12) : Color.clear
    }

    private func fileRow(_ file: AgentChangedFile) -> some View {
        Button {
            if let step = steps.first(where: { $0.id == file.stepID }) { selection = AgentResultPreview.tool(step) }
            previewError = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 16)
                Text(verbatim: file.target.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let change = file.changeLabel(localize: localized) {
                    Text(verbatim: change).foregroundStyle(.secondary).fixedSize()
                }
            }
            .font(.scaled(.callout))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(rowBackground(file.stepID), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func stepRow(_ step: AgentTranscriptItem) -> some View {
        let label = AgentStepWording.label(for: step, context: context, localize: localized)
        var status = AgentToolStatus.succeeded
        if case .tool(_, _, _, _, let state) = step { status = state }
        let working = controller.state == .running
        return Button { selection = AgentResultPreview.tool(step); previewError = nil } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: status == .failed ? "exclamationmark.circle" : status == .running ? "ellipsis" : "checkmark")
                    .foregroundStyle(status == .failed ? LBTokens.Palette.attentionText : Color.secondary)
                    .frame(width: 16)
                Text(verbatim: label?.text(status, taskIsWorking: working, localize: localized) ?? "").lineLimit(1)
                Spacer(minLength: 8)
                if let detail = label?.detail {
                    Text(verbatim: detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.scaled(.callout))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(rowBackground(step.id), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// A step's preview is headed by its plain label; other previews keep their own title.
    private func selectedPreview(_ selected: AgentResultPreview) -> some View {
        let step = steps.first { $0.id == selected.id }
        let file = changedFiles.first { $0.stepID == selected.id }
        let label = step.flatMap { AgentStepWording.label(for: $0, context: context, localize: localized) }
        let title = file?.target.name ?? label?.done ?? selected.title
        let detail = file?.detail(localize: localized) ?? label?.detail ?? selected.detail
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(.scaled(.headline)).lineLimit(2)
                    Text(verbatim: detail).font(.scaled(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(3).truncationMode(.middle)
                }
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy").accessibilityLabel("Copy result")
                Button { exporting = true } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export result").accessibilityLabel("Export result")
            }.buttonStyle(.borderless).padding(16)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if let original = selected.original, let proposed = selected.proposed {
                        change("Before", text: original, color: LBTokens.Palette.recording)
                        change("After", text: proposed, color: LBTokens.Palette.success)
                    }
                    SelectableDigestText(selected.text, style: .agent)
                        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    Text("Preview of recorded output or selected source. Opening a preview does not run a tool.")
                        .font(.scaled(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    private func change(_ label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.scaled(.caption).weight(.semibold))
            Text(text.isEmpty ? "(empty)" : text).font(.scaled(.caption, design: .monospaced)).textSelection(.enabled)
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
