#if canImport(UIKit)
import SwiftUI
import Storybook
import StorybookRuntime

/// The story tree, Storybook-style: path groups, components and their
/// stories. Opens at half height and scrolls in place; drag up for more.
struct StoriesSheet: View {
    let session: StorybookSession
    let onDone: () -> Void
    @State private var search = ""
    @State private var collapsed: Set<String> = []

    private var store: StoryStore { session.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { reader in
                List {
                    ForEach(StoryTree.sections(store.stories, matching: search)) { section in
                        // A plain row rather than a sticky header, which is translucent.
                        if !section.name.isEmpty {
                            Text(section.name.uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.components) { component in
                            componentRows(component)
                        }
                    }
                    if !store.discoveryErrors.isEmpty {
                        Section("Problems") {
                            ForEach(store.discoveryErrors, id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.red)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if store.stories.isEmpty {
                        ContentUnavailableView("No stories", systemImage: "books.vertical",
                                               description: Text("Link a module that declares `Stories` types."))
                    } else if !search.isEmpty, StoryTree.sections(store.stories, matching: search).isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .onAppear {
                    if let id = store.selectedID { reader.scrollTo(id, anchor: .center) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Solid, so the story (and section headers) don't smear through glass.
        .presentationBackground(.background)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Stories").font(.title2.bold())
                Spacer()
                ConnectionButton(session: session)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                Button("Done", action: onDone)
                    .fontWeight(.semibold)
                    .padding(.leading, 12)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find stories", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func componentRows(_ component: StoryTree.Component) -> some View {
        // Searching shows every match, whatever was collapsed.
        let isExpanded = !search.isEmpty || !collapsed.contains(component.id)
        Button {
            withAnimation(.snappy) {
                if collapsed.contains(component.id) { collapsed.remove(component.id) } else { collapsed.insert(component.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: "square.grid.2x2").foregroundStyle(.blue)
                Text(component.name).font(.body.weight(.medium))
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

        if isExpanded {
            ForEach(component.stories) { story in
                storyRow(story)
            }
        }
    }

    private func storyRow(_ story: ResolvedStory) -> some View {
        let isSelected = story.id == store.selectedID
        return Button {
            if isSelected { onDone() } else { try? store.select(story.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.teal))
                Text(story.name)
                Spacer()
            }
            .padding(.leading, 40)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor : .clear)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(story.id)
    }
}

/// Groups stories by title the way Storybook's sidebar does:
/// `Design System/Pay Button` → section "Design System", component "Pay Button".
enum StoryTree {
    struct Section: Identifiable {
        let name: String
        let components: [Component]
        var id: String { name }
    }

    struct Component: Identifiable {
        let title: String
        let name: String
        let stories: [ResolvedStory]
        var id: String { title }
    }

    static func sections(_ stories: [ResolvedStory], matching search: String) -> [Section] {
        let matching = stories.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)
        }
        // Stories arrive sorted; keep their order within each component.
        var components: [String: [ResolvedStory]] = [:]
        var titles: [String] = []
        for story in matching {
            if components[story.title] == nil { titles.append(story.title) }
            components[story.title, default: []].append(story)
        }
        var sections: [String: [Component]] = [:]
        var names: [String] = []
        for title in titles {
            var parts = title.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts.popLast() ?? title
            let section = parts.joined(separator: " / ")
            if sections[section] == nil { names.append(section) }
            sections[section, default: []].append(Component(title: title, name: name, stories: components[title] ?? []))
        }
        return names.sorted().map { Section(name: $0, components: sections[$0] ?? []) }
    }
}
#endif
