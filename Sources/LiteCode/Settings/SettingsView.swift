import SwiftUI

/// Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(EditorSettings.fontSizeKey) private var editorFontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var sidebarFontSize = EditorSettings.defaultSidebarFontSize
    @AppStorage(EditorSettings.tabFontSizeKey) private var tabFontSize = EditorSettings.defaultTabFontSize
    @AppStorage(EditorSettings.terminalFontSizeKey) private var terminalFontSize = EditorSettings.defaultTerminalFontSize
    @AppStorage(EditorSettings.autoSaveKey) private var autoSave = AutoSaveMode.off
    @AppStorage(EditorSettings.autoSaveDelayKey) private var autoSaveDelay = EditorSettings.defaultAutoSaveDelay
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section("Editor") {
                Picker("Font family", selection: $fontFamily) {
                    Text("SF Mono (System)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                sizeRow("Font size", value: $editorFontSize, range: EditorSettings.fontSizeRange)
                Text(verbatim: "let greeting = \"Hello\" + name  // 0O 1lI {}[] => !=")
                    .font(Font(EditorSettings.font(family: fontFamily, size: editorFontSize)))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Section("Interface") {
                sizeRow("Sidebar font size", value: $sidebarFontSize, range: EditorSettings.uiFontSizeRange)
                sizeRow("Tab bar font size", value: $tabFontSize, range: EditorSettings.uiFontSizeRange)
            }
            Section("Terminal") {
                sizeRow("Font size", value: $terminalFontSize, range: EditorSettings.fontSizeRange)
            }
            Section("Files") {
                Picker("Auto Save", selection: $autoSave) {
                    ForEach(AutoSaveMode.allCases) { mode in
                        Text(mode == .off ? "off (default)" : mode.rawValue).tag(mode)
                    }
                }
                Text(autoSave.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if autoSave == .afterDelay {
                    Stepper(value: $autoSaveDelay, in: EditorSettings.autoSaveDelayRange, step: 100) {
                        HStack {
                            Text("Auto Save Delay")
                            Spacer()
                            Text("\(Int(autoSaveDelay)) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Restore Defaults") {
                    editorFontSize = EditorSettings.defaultFontSize
                    fontFamily = ""
                    sidebarFontSize = EditorSettings.defaultSidebarFontSize
                    tabFontSize = EditorSettings.defaultTabFontSize
                    terminalFontSize = EditorSettings.defaultTerminalFontSize
                    autoSave = .off
                    autoSaveDelay = EditorSettings.defaultAutoSaveDelay
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if families.isEmpty { families = EditorSettings.monospacedFamilies } }
        // Text views hold their own fonts; restyle open editors when the editor font changes.
        .onChange(of: editorFontSize) { Workspaces.shared.refreshEditorFonts() }
        .onChange(of: fontFamily) { Workspaces.shared.refreshEditorFonts() }
        .onChange(of: terminalFontSize) { Workspaces.shared.refreshTerminalFonts() }
    }

    private func sizeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
