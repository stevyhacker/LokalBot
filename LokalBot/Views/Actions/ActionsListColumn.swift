import AppKit
import SwiftUI

/// The one row of controls above the Actions list: which status to show, the
/// Filter menu with its choices as removable chips, and the search field.
struct ActionsFilterBar: View {
    @Binding var filter: ActionsListFilter
    let chips: [ActionsListFilter.Chip]
    let links: ActionThreadLinks
    let meetingTitles: [String]

    var body: some View {
        // One row when it fits. More chips than the row holds go to a row
        // of their own, and in a narrow list so does the search field.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statusPicker
                filterMenu
                chipRow
                Spacer(minLength: 0)
                searchField.frame(width: Self.searchWidth)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusPicker
                    filterMenu
                    Spacer(minLength: 0)
                    searchField.frame(width: Self.searchWidth)
                }
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { chipRow }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusPicker
                    filterMenu
                    Spacer(minLength: 0)
                }
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) { chipRow }
                }
                searchField
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }

    private static let searchWidth: CGFloat = 230

    private var statusPicker: some View {
        Picker("Status", selection: Binding(get: { filter.status }, set: { filter.show($0) })) {
            ForEach([OutcomeStatus.open, .deferred, .done], id: \.self) { status in
                Text(LocalizedStringKey(status.stateKey)).tag(status)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("actions.status")
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in chipButton(chip) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Due", selection: $filter.due) {
                Text("Any date").tag(ActionsListFilter.Due.any)
                Text("Overdue").tag(ActionsListFilter.Due.overdue)
                Text("Has a date").tag(ActionsListFilter.Due.dated)
                Text("No date").tag(ActionsListFilter.Due.undated)
            }
            .pickerStyle(.inline)
            Divider()
            // People and Projects only know open and deferred work.
            if !links.people.isEmpty {
                Picker("Person", selection: optional(\.personID)) {
                    Text("Anyone").tag("")
                    ForEach(links.people) { person in
                        Text(verbatim: person.name).tag(person.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(filter.status == .done)
            }
            if !links.projects.isEmpty {
                Picker("Project", selection: optional(\.projectID)) {
                    Text("Any project").tag("")
                    ForEach(links.projects) { project in
                        Text(verbatim: project.name).tag(project.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(filter.status == .done)
            }
            if !meetingTitles.isEmpty {
                Picker("Meeting", selection: optional(\.meetingTitle)) {
                    Text("Any meeting").tag("")
                    ForEach(meetingTitles, id: \.self) { title in
                        Text(verbatim: title).tag(title)
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("Not mentioned in 3 weeks", isOn: $filter.staleOnly)
                .disabled(filter.status != .open)
            Divider()
            Picker("Group by", selection: Binding(get: { filter.grouping }, set: {
                filter.grouping = $0
                filter.staleOnly = false
            })) {
                Text("Due date").tag(ActionsListFilter.Grouping.due)
                Text("Meeting").tag(ActionsListFilter.Grouping.meeting)
                Text("None").tag(ActionsListFilter.Grouping.none)
            }
            .pickerStyle(.inline)
            .disabled(filter.status != .open)
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
        }
        .fixedSize()
        .accessibilityIdentifier("actions.filter")
    }

    /// A Filter menu submenu stores "no choice" as nil; its picker tags it "".
    private func optional(_ keyPath: WritableKeyPath<ActionsListFilter, String?>) -> Binding<String> {
        Binding(get: { filter[keyPath: keyPath] ?? "" },
                set: { filter[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func chipButton(_ chip: ActionsListFilter.Chip) -> some View {
        Button {
            filter.remove(chip.kind)
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: chip.label).lineLimit(1).fixedSize()
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(AppFont.scaled(.callout).weight(.medium))
            .foregroundStyle(Brand.teal)
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(Brand.teal.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Remove filter")
        .accessibilityLabel(Text(verbatim: chip.label))
        .accessibilityHint("Remove filter")
        .accessibilityIdentifier("actions.chip.\(chip.kind)")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search actions and meetings", text: $filter.query)
                .textFieldStyle(.plain)
                .font(.scaled(.body))
                .accessibilityIdentifier("actions.search")
            if !filter.query.isEmpty {
                Button {
                    filter.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .workspaceControl()
    }
}

/// The Actions list: the shared action row under the content's headings.
/// The list is lazy and every row's wording is already in `content`.
struct ActionsList: View {
    let content: ActionsListContent
    /// The rows the details pane is about.
    let current: Set<String>
    let emptyText: String
    let offersClearFilters: Bool
    let onClick: (_ id: String, _ command: Bool, _ shift: Bool) -> Void
    /// Moves the selection one row and returns the row to keep in view.
    let onMove: (_ step: Int, _ extending: Bool) -> String?
    let onSelectAll: () -> Void
    let onCollapse: () -> Void
    let onStatus: (OutcomeStatus, ActionThread) -> Void
    let onEdit: (ActionThread) -> Void
    let onNotMine: (ActionThread) -> Void
    let onClearFilters: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(content.sections) { section in
                        if let title = section.title {
                            heading(title, section: section)
                        }
                        ForEach(section.rows) { row in
                            ActionThreadRow(thread: row.thread, list: ActionListRowStyle(
                                source: row.source, due: row.due,
                                isSelected: current.contains(row.id), isBatch: current.count > 1,
                                onStatus: { onStatus($0, row.thread) },
                                onEdit: { onEdit(row.thread) },
                                onNotMine: { onNotMine(row.thread) }))
                                .onTapGesture { click(row.id) }
                                .accessibilityAction(named: Text("Show Details")) { onClick(row.id, false, false) }
                                .id(row.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .overlay(alignment: .top) {
                if content.isEmpty { empty }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard let id = onMove(press.key == .upArrow ? -1 : 1, press.modifiers.contains(.shift)) else {
                    return .ignored
                }
                proxy.scrollTo(id)
                return .handled
            }
            .onKeyPress(.escape) {
                guard current.count > 1 else { return .ignored }
                onCollapse()
                return .handled
            }
            .onCommand(#selector(NSResponder.selectAll(_:)), perform: onSelectAll)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actions.list")
        .accessibilityLabel("Actions")
    }

    /// The modifier keys held at the click choose between one row, adding a
    /// row, and a range.
    private func click(_ id: String) {
        let modifiers = NSEvent.modifierFlags
        focused = true
        onClick(id, modifiers.contains(.command), modifiers.contains(.shift))
    }

    private func heading(_ title: String, section: ActionsListContent.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title)
                .font(AppFont.scaled(.callout).weight(.bold))
                .foregroundStyle(section.isLate ? AnyShapeStyle(LBTokens.Palette.recordingText) : AnyShapeStyle(.primary))
            Text(section.rows.count, format: .number)
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(verbatim: emptyText)
                .font(.scaled(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if offersClearFilters {
                Button("Clear filters", action: onClearFilters)
                    .buttonStyle(.workspaceLink)
                    .accessibilityIdentifier("actions.clearFilters")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 64)
        .accessibilityIdentifier("actions.empty")
    }
}

/// "8 open actions haven’t been mentioned in 3 weeks. Review": the quiet bar
/// under the list that replaces the "Still open?" question on each row.
struct ActionsStaleBar: View {
    let summary: String
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .foregroundStyle(LBTokens.Palette.attentionText)
                .accessibilityHidden(true)
            Text(verbatim: summary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Review", action: onReview)
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("actions.staleReview")
            Spacer(minLength: 0)
        }
        .font(AppFont.scaled(.callout))
        .padding(.horizontal, 16)
        .frame(minHeight: 34)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actions.staleBar")
    }
}
