import SwiftUI

/// Foundation parses block structure; SwiftUI's Text renders the inline attributes.
/// Selection is enabled by callers (the meeting summary reserves double-click for editing).
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        MarkdownBlocks(blocks: MarkdownBlock.parse(markdown))
    }
}

struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: PresentationIntent.Kind
    var text = AttributedString()
    var children: [MarkdownBlock] = []

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        guard let parsed = try? AttributedString(
            markdown: markdown, options: .init(interpretedSyntax: .full)
        ) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        var blocks: [MarkdownBlock] = []
        for run in parsed.runs {
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .body.monospaced()
            }
            let path = run.presentationIntent?.components.reversed().map { $0 } ?? []
            append(text, path: path[...], to: &blocks)
        }
        return blocks
    }

    private static func append(
        _ text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>,
        to blocks: inout [MarkdownBlock]
    ) {
        guard let intent = path.first else {
            blocks.append(MarkdownBlock(id: -blocks.count - 1, kind: .paragraph, text: text))
            return
        }
        if blocks.last?.id != intent.identity {
            blocks.append(MarkdownBlock(id: intent.identity, kind: intent.kind))
        }
        let index = blocks.count - 1
        if path.count == 1 {
            blocks[index].text.append(text)
        } else {
            append(text, path: path.dropFirst(), to: &blocks[index].children)
        }
    }

    func cell(at column: Int) -> AttributedString {
        children.first { $0.kind == .tableCell(columnIndex: column) }?.text ?? AttributedString()
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    var ordered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, ordered: ordered)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var ordered = false

    var body: some View {
        // Type erasure terminates the recursive SwiftUI view type for nested lists and quotes.
        AnyView(content)
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font(.system(size: [26, 22, 19, 17, 15, 13][min(max(level, 1), 6) - 1], weight: .bold))
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
        case .orderedList, .unorderedList:
            MarkdownBlocks(blocks: block.children, ordered: block.kind == .orderedList)
        case .listItem(let ordinal):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordered ? "\(ordinal)." : "•").monospacedDigit()
                MarkdownBlocks(blocks: block.children)
            }.padding(.leading, 10)
        case .blockQuote:
            HStack(alignment: .top, spacing: 10) {
                MarkdownBlocks(blocks: block.children)
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
            }
            .foregroundStyle(.secondary)
        case .codeBlock(let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(String(block.text.characters))
                        .font(.body.monospaced())
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .thematicBreak:
            Divider().padding(.vertical, 4)
        case .table(let columns):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(block.children) { row in
                        GridRow {
                            ForEach(columns.indices, id: \.self) { index in
                                let alignment = alignment(columns[index].alignment)
                                Text(row.cell(at: index))
                                    .fontWeight(row.kind == .tableHeaderRow ? .semibold : .regular)
                                    .multilineTextAlignment(columns[index].alignment == .right ? .trailing
                                        : columns[index].alignment == .center ? .center : .leading)
                                    .frame(minWidth: 50, maxWidth: 320, alignment: alignment)
                                    .padding(8)
                                    .gridColumnAlignment(alignment.horizontal)
                            }
                        }
                        .background(row.kind == .tableHeaderRow ? Color.primary.opacity(0.06) : .clear)
                        .overlay(alignment: .bottom) { Divider() }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        default:
            Text(block.text)
        }
    }

    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch value {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}
