import Foundation
import Testing
@testable import TheExplorer

struct MarkdownTests {
    private func text(_ attributed: AttributedString) -> String { String(attributed.characters) }

    @Test func headingsParagraphsAndRules() {
        let document = MarkdownDocument("""
        # Title ##
        Some *soft*
        wrapped text.

        Setext
        ------
        ***
        """)
        guard document.blocks.count == 4,
              case .heading(1, let title, "title") = document.blocks[0],
              case .paragraph(let paragraph) = document.blocks[1],
              case .heading(2, let setext, _) = document.blocks[2],
              case .rule = document.blocks[3] else {
            Issue.record("Unexpected blocks: \(document.blocks)")
            return
        }
        #expect(text(title) == "Title")
        #expect(text(paragraph) == "Some soft wrapped text.")
        #expect(text(setext) == "Setext")
    }

    @Test func listsNestAndTasksAreChecked() {
        let document = MarkdownDocument("""
        - one
          - nested
            continued
        - [x] done
        - [ ] todo
        3. third
        """)
        let items = document.blocks.compactMap { block -> (Int, MarkdownDocument.Marker, String)? in
            guard case .listItem(let depth, let marker, let text) = block else { return nil }
            return (depth, marker, String(text.characters))
        }
        #expect(items.map(\.0) == [0, 1, 0, 0, 0])
        #expect(items.map(\.1) == [.bullet, .bullet, .task(done: true), .task(done: false), .number(3)])
        #expect(items[1].2 == "nested continued")
    }

    @Test func fencedCodeKeepsItsText() {
        let document = MarkdownDocument("""
        ```swift
        let x = 1
          indented()
        ```
        after
        """)
        #expect(document.blocks.first == .code(language: "swift", text: "let x = 1\n  indented()"))
        #expect(document.blocks.count == 2)
    }

    @Test func tablesWithAlignmentAndPipesInCode() {
        let document = MarkdownDocument("""
        | Name | Size |
        | :--- | ---: |
        | `a|b` | 12 |
        | short |
        """)
        guard case .table(let table) = document.blocks.first else {
            Issue.record("No table: \(document.blocks)")
            return
        }
        #expect(table.alignments == [.leading, .trailing])
        #expect(table.header.map(text) == ["Name", "Size"])
        #expect(table.rows.map { $0.map(text) } == [["a|b", "12"], ["short", ""]])
    }

    @Test func readmeImagesAndHTMLBecomeImagesAndText() {
        let document = MarkdownDocument("""
        <div align="center">
        <img src="docs/icon.png" width="128" alt="Icon">

        ![macOS](https://img.shields.io/badge/macOS-15)
        [![Swift](https://img.shields.io/swift)](https://swift.org)
        <!-- a
        comment -->
        <sub>Caption</sub>
        </div>
        """)
        guard document.blocks.count == 3,
              case .images(let icon) = document.blocks[0],
              case .images(let badges) = document.blocks[1],
              case .paragraph(let caption) = document.blocks[2] else {
            Issue.record("Unexpected blocks: \(document.blocks)")
            return
        }
        #expect(icon == [.init(alt: "Icon", source: "docs/icon.png", width: 128)])
        #expect(badges.map(\.alt) == ["macOS", "Swift"])
        #expect(text(caption) == "Caption")
    }

    @Test func quotesFrontMatterAndAnchors() {
        let document = MarkdownDocument("""
        ---
        title: Hi
        ---
        > quoted **text**
        > more

        ## Getting started!
        ## Getting started!
        """)
        #expect(document.blocks.first == .code(language: "yaml", text: "title: Hi"))
        guard case .quote(let inner) = document.blocks[1], case .paragraph(let quoted) = inner.first else {
            Issue.record("No quote: \(document.blocks)")
            return
        }
        #expect(text(quoted) == "quoted text more")
        #expect(document.anchors["getting-started"] == 2)
        #expect(document.anchors["getting-started-1"] == 3)
    }

    @Test func autolinksAreNotStrippedAsTags() {
        #expect(MarkdownDocument.stripTags("see <https://a.b> and <b>bold</b>") == "see <https://a.b> and bold")
    }
}

struct DelimitedTableTests {
    @Test func quotedFieldsAndCRLF() {
        let csv = "name,note,amount\r\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\",\"1,200\"\r\nLee,,3\r\n\r\n"
        let table = DelimitedTable(Data(csv.utf8))
        #expect(table.header == ["name", "note", "amount"])
        #expect(table.rows == [["Smith, J", "said \"hi\"\nthen left", "1,200"], ["Lee", "", "3"]])
        #expect(table.totalRows == 2)
        #expect(table.numeric == [false, false, true])
    }

    @Test func sniffsSemicolonsAndTabs() {
        #expect(DelimitedTable(Data("a;b;c\n1;2,5;3\n".utf8)).header == ["a", "b", "c"])
        #expect(DelimitedTable(Data("a\tb\n1\t2\n".utf8)).delimiter == 0x09)
    }

    @Test func keepsTheFirstRowsAndCountsTheRest() {
        let csv = "n\n" + (1...5000).map(String.init).joined(separator: "\n")
        let table = DelimitedTable(Data(csv.utf8), maxRows: 100)
        #expect(table.rows.count == 100)
        #expect(table.totalRows == 5000)
        #expect(table.rows.last == ["100"])
    }

    @Test func raggedRowsArePadded() {
        let table = DelimitedTable(Data("a,b\n1\n1,2,3\n".utf8))
        #expect(table.columns == 3)
        #expect(table.rows == [["1", "", ""], ["1", "2", "3"]])
    }

    @Test func latin1Files() {
        let table = DelimitedTable(Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x31]))
        #expect(table.header == ["café"])
    }
}

struct JSONTreeTests {
    @Test func keepsKeyOrderAndNumberText() throws {
        let tree = try JSONTree(Data(#"{"z": 1.50, "a": [true, null, "x\né😀"], "m": {}}"#.utf8))
        let root = tree.children(of: 0)
        #expect(root.map { tree.nodes[$0].key } == ["z", "a", "m"])
        #expect(tree.nodes[root[0]].value == "1.50")
        let array = tree.children(of: root[1])
        #expect(array.map { tree.nodes[$0].kind } == [.bool, .null, .string])
        #expect(tree.nodes[array[2]].value == "x\né😀")
        #expect(tree.nodes[root[2]].count == 0)
    }

    @Test func pathsAndCopiedText() throws {
        let tree = try JSONTree(Data(#"{"users": [{"first name": "Ada"}, {"id": 2}]}"#.utf8))
        let users = tree.children(of: 0)[0]
        let second = tree.children(of: users)[1]
        let id = tree.children(of: second)[0]
        let name = tree.children(of: tree.children(of: users)[0])[0]
        #expect(tree.path(to: id) == ".users[1].id")
        #expect(tree.path(to: name) == #".users[0]["first name"]"#)
        #expect(tree.path(to: 0) == ".")
        #expect(tree.text(at: name) == "Ada")
        #expect(tree.text(at: second) == "{\n  \"id\": 2\n}")
    }

    @Test func commentsAndTrailingCommas() throws {
        let tree = try JSONTree(Data("""
        {
          // compiler options
          "strict": true, /* yes */
          "paths": ["a", "b",],
        }
        """.utf8))
        #expect(tree.children(of: 0).count == 2)
    }

    @Test func jsonLines() throws {
        let tree = try JSONTree(Data("{\"a\":1}\n{\"a\":2}\n\n[3]\n".utf8))
        #expect(tree.isLines)
        #expect(tree.nodes[0].count == 3)
    }

    @Test func errorsSayWhere() {
        #expect(throws: JSONTree.ParseError.self) { try JSONTree(Data("{\n  \"a\": tru\n}".utf8)) }
        do {
            _ = try JSONTree(Data("{\n  \"a\": 1\n  \"b\": 2\n}".utf8))
        } catch let error as JSONTree.ParseError {
            #expect(error.line == 3)
            #expect(error.message.contains("Expected"))
        } catch {
            Issue.record("Wrong error \(error)")
        }
    }

    @Test func deepNestingDoesNotOverflowTheStack() throws {
        let deep = String(repeating: "[", count: 100_000) + "1" + String(repeating: "]", count: 100_000)
        let tree = try JSONTree(Data(deep.utf8))
        #expect(tree.nodes.count == 100_001)
        #expect(tree.path(to: 3) == ".[0][0][0]")
    }
}

struct RenderedKindTests {
    @Test func kindsByExtension() {
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/README.md"), type: nil) == .markdown)
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/data.TSV"), type: nil) == .table)
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/tsconfig.json"), type: nil) == .json)
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/events.ndjson"), type: nil) == .json)
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/font.ttf"), type: .init(filenameExtension: "ttf")) == .font)
        #expect(RenderedKind(url: URL(fileURLWithPath: "/a/notes.txt"), type: .plainText) == nil)
    }

    @Test func systemFontsLoadWithTheirFaces() throws {
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let faces = try #require(FontFaces(url: url))
        #expect(faces.faces.first?.family == "Arial")
        #expect(faces.sample == nil)
    }
}
