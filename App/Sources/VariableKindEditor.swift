import SwiftUI
import WrdsKit

/// The kinds a variable can be, as something a `Picker` can show.
///
/// `globalCases` is the same list minus `.global`: a global variable that pointed at another global
/// would be an alias, and `ExpansionRenderer` deliberately resolves globals one hop only.
enum VariableKindOption: String, CaseIterable, Identifiable {
    case echo, date, clipboard, choice, shell, form, global

    static let globalCases: [VariableKindOption] = [.echo, .date, .clipboard, .choice, .shell, .form]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .echo: return String(localized: "Fixed text")
        case .date: return String(localized: "Date")
        case .clipboard: return String(localized: "Clipboard")
        case .choice: return String(localized: "Choice")
        case .shell: return String(localized: "Shell")
        case .form: return String(localized: "Ask me")
        case .global: return String(localized: "Global")
        }
    }

    init(matching kind: Variable.Kind) {
        switch kind {
        case .echo: self = .echo
        case .date: self = .date
        case .clipboard: self = .clipboard
        case .choice: self = .choice
        case .shell: self = .shell
        case .form: self = .form
        case .global: self = .global
        }
    }

    /// What a freshly picked kind starts out as, before the user fills anything in.
    var defaultValue: Variable.Kind {
        switch self {
        case .echo: return .echo(value: "")
        case .date: return .date(format: "%Y-%m-%d", offsetSeconds: 0)
        case .clipboard: return .clipboard
        case .choice: return .choice(options: [])
        case .shell: return .shell(command: "", timeoutSeconds: 5)
        case .form: return .form(fields: [FormField(name: "field1", label: "Question 1",
                                                    kind: .text(default: ""))])
        case .global: return .global(name: "")
        }
    }
}

/// The fields one `Variable.Kind` needs, and the only place they are spelled out.
///
/// Shared by `VariableConfigPopover` (a snippet's own variables) and `GlobalsEditorView` (the shared
/// ones), so there is one editor per kind rather than one per pane.
///
/// `onCommit` is called for discrete changes — adding an option, moving a stepper, submitting a field
/// — and not on every keystroke: the callers persist to disk, and a text field that saved per
/// character would rewrite `store.json` as fast as someone can type. Both callers also commit when
/// their editor goes away, which is what catches a field left mid-edit.
struct VariableKindEditor: View {
    @Binding var kind: Variable.Kind
    /// Globals the `.global` picker can point at. Empty when the thing being edited *is* a global.
    var globals: [GlobalVariable] = []
    /// Whether pointing at a global is a thing this variable may do at all. `false` for a global
    /// variable, which cannot wrap another one — the renderer resolves globals one hop only.
    var allowsGlobalReference = true
    let onCommit: () -> Void

    @ViewBuilder var body: some View {
        switch kind {
        case .echo(let value):
            VStack(alignment: .leading, spacing: 6) {
                TextField("Value", text: binding(value) { .echo(value: $0) }, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(onCommit)
                note("Inserted as written. Variables inside it are filled in too.")
            }

        case .date(let format, let offsetSeconds):
            DateVariableFields(
                format: binding(format) { .date(format: $0, offsetSeconds: offsetSeconds) },
                offsetSeconds: binding(offsetSeconds, commits: true) {
                    .date(format: format, offsetSeconds: $0)
                },
                onCommit: onCommit)

        case .clipboard:
            note("""
                Pastes what you've copied, at the moment the snippet expands. Nothing to set up.
                """)

        case .choice(let options):
            VStack(alignment: .leading, spacing: 6) {
                OptionListEditor(options: binding(options) { .choice(options: $0) }, onCommit: onCommit)
                note("One of these, picked at random each time the snippet expands.")
            }

        case .shell(let command, let timeoutSeconds):
            ShellVariableFields(
                command: binding(command) { .shell(command: $0, timeoutSeconds: timeoutSeconds) },
                timeoutSeconds: binding(timeoutSeconds, commits: true) {
                    .shell(command: command, timeoutSeconds: $0)
                },
                onCommit: onCommit)

        case .form(let fields):
            FormFieldsEditor(fields: binding(fields) { .form(fields: $0) }, onCommit: onCommit)

        case .global(let name):
            globalPicker(selected: name)
        }
    }

    /// A binding onto one part of the current kind, which writing rebuilds the whole kind from.
    ///
    /// `commits` is for the controls that change in one discrete step — a stepper, a numeric field —
    /// where waiting for a submit that never comes would lose the edit.
    private func binding<Value>(_ value: Value, commits: Bool = false,
                                _ rebuild: @escaping (Value) -> Variable.Kind) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                kind = rebuild(newValue)
                if commits { onCommit() }
            }
        )
    }

    @ViewBuilder private func globalPicker(selected: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !allowsGlobalReference {
                note("""
                    A global variable can't point to another global variable. Pick one of the types \
                    above.
                    """)
            } else if globals.isEmpty {
                note("""
                    No global variables yet. Add one under Global Variables in the sidebar, then \
                    choose it here.
                    """)
            } else {
                Picker("Global variable", selection: binding(selected, commits: true) {
                    .global(name: $0)
                }) {
                    if !globals.contains(where: { $0.variable.name == selected }) {
                        Text(selected.isEmpty ? "Choose\u{2026}" : "\(selected) (missing)").tag(selected)
                    }
                    ForEach(globals) { Text($0.variable.name).tag($0.variable.name) }
                }
                note("""
                    Uses the value of the global variable you pick. Change that variable and every \
                    snippet that uses it follows.
                    """)
            }
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// strftime format, an offset, and what the two produce right now.
private struct DateVariableFields: View {
    @Binding var format: String
    @Binding var offsetSeconds: Int
    let onCommit: () -> Void

    @State private var unit: OffsetUnit = .days

    /// How an offset is spelled in the editor. Stored as seconds either way — this only decides what
    /// the stepper counts in.
    private enum OffsetUnit: String, CaseIterable, Identifiable {
        case seconds, minutes, hours, days

        var id: String { rawValue }

        var title: String {
            switch self {
            case .seconds: return String(localized: "seconds")
            case .minutes: return String(localized: "minutes")
            case .hours: return String(localized: "hours")
            case .days: return String(localized: "days")
            }
        }

        var length: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            case .days: return 86_400
            }
        }

        /// The largest unit `offset` is a whole number of, so an offset of a day opens as "1 day"
        /// rather than as 86,400 seconds.
        static func fitting(_ offset: Int) -> OffsetUnit {
            guard offset != 0 else { return .days }
            for unit in [OffsetUnit.days, .hours, .minutes] where offset % unit.length == 0 {
                return unit
            }
            return .seconds
        }
    }

    private var amount: Binding<Int> {
        Binding(
            get: { offsetSeconds / unit.length },
            set: { offsetSeconds = $0 * unit.length }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Format", text: $format)
                .font(.system(.body, design: .monospaced))
                .onSubmit(onCommit)
            LabeledContent("Offset") {
                HStack(spacing: 4) {
                    TextField("Offset", value: amount, format: .number)
                        .labelsHidden()
                        .frame(width: 64)
                    Stepper("Offset", value: amount)
                        .labelsHidden()
                    Picker("Unit", selection: $unit) {
                        ForEach(OffsetUnit.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 104)
                }
            }
            LabeledContent("Right now") {
                Text(example)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("Codes: %Y year, %m month, %d day, %H:%M:%S time, %A weekday, %B month name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { unit = OffsetUnit.fitting(offsetSeconds) }
    }

    /// What this format and offset render to at this moment — the fastest way to find out whether a
    /// half-remembered strftime token does what you hoped.
    private var example: String {
        StrftimeFormatter.format(format, date: Date().addingTimeInterval(Double(offsetSeconds)))
    }
}

/// A command, how long it may take, and a promise that neither runs while you are editing.
private struct ShellVariableFields: View {
    @Binding var command: String
    @Binding var timeoutSeconds: Double
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Command", text: $command, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...4)
                .onSubmit(onCommit)
            LabeledContent("Timeout") {
                TextField("Timeout", value: Binding(
                    get: { timeoutSeconds },
                    set: { timeoutSeconds = Self.clampTimeout($0) }
                ), format: .number)
                .labelsHidden()
                .frame(width: 72)
                .help("The command is stopped after this many seconds.")
            }
            Text("""
                The command runs each time the snippet expands. It doesn't run while you edit or in \
                the preview.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Clamped to `(0, 3600]`: zero or negative reads to `ShellRunner` as "killed instantly", a
    /// non-finite value is a wait that never ends, and nothing past an hour is a timeout a snippet
    /// should ever be blocking an expansion on.
    private static func clampTimeout(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return min(value, 3600)
    }
}

/// An editable list of strings — a choice variable's options, or a choice field's.
struct OptionListEditor: View {
    @Binding var options: [String]
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    TextField("Option", text: Binding(
                        get: { options.indices.contains(index) ? options[index] : "" },
                        set: { if options.indices.contains(index) { options[index] = $0 } }
                    ))
                    .onSubmit(onCommit)
                    Button {
                        guard options.indices.contains(index) else { return }
                        options.remove(at: index)
                        onCommit()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove this option")
                }
            }
            Button("Add Option") {
                options.append("")
                onCommit()
            }
            .buttonStyle(.link)
        }
    }
}

/// The fields a form variable asks for, each with its own name, label and kind.
private struct FormFieldsEditor: View {
    @Binding var fields: [FormField]
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fields.indices, id: \.self) { index in
                if fields.indices.contains(index) { row(index) }
            }
            Button("Add Question") {
                fields.append(FormField(name: nextFieldName(), label: "", kind: .text(default: "")))
                onCommit()
            }
            .buttonStyle(.link)
            Text("Each question is asked when the snippet expands. Use {{variable.field}} in the content for each answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("Name", text: field(index, \.name)).onSubmit(onCommit)
                Button {
                    guard fields.indices.contains(index) else { return }
                    fields.remove(at: index)
                    onCommit()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove this question")
            }
            TextField("Question", text: field(index, \.label)).onSubmit(onCommit)
            Picker("Type", selection: kindSelection(index)) {
                Text("Text").tag(FieldKind.text)
                Text("Multiline").tag(FieldKind.multiline)
                Text("Choice").tag(FieldKind.choice)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            kindFields(index, kind: fields[index].kind)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    @ViewBuilder private func kindFields(_ index: Int, kind: FormField.Kind) -> some View {
        switch kind {
        case .text(let defaultValue):
            TextField("Default", text: defaultBinding(index, current: defaultValue) {
                .text(default: $0)
            })
            .onSubmit(onCommit)
        case .multiline(let defaultValue):
            TextField("Default", text: defaultBinding(index, current: defaultValue) {
                .multiline(default: $0)
            }, axis: .vertical)
            .lineLimit(1...4)
            .onSubmit(onCommit)
        case .choice(let options):
            OptionListEditor(options: Binding(
                get: { options },
                set: { newOptions in
                    guard fields.indices.contains(index) else { return }
                    fields[index].kind = .choice(options: newOptions)
                }
            ), onCommit: onCommit)
        }
    }

    /// The three shapes a form field can take, as something a `Picker` can select.
    private enum FieldKind: Hashable {
        case text, multiline, choice

        init(matching kind: FormField.Kind) {
            switch kind {
            case .text: self = .text
            case .multiline: self = .multiline
            case .choice: self = .choice
            }
        }

        var defaultValue: FormField.Kind {
            switch self {
            case .text: return .text(default: "")
            case .multiline: return .multiline(default: "")
            case .choice: return .choice(options: [])
            }
        }
    }

    private func kindSelection(_ index: Int) -> Binding<FieldKind> {
        Binding(
            get: { fields.indices.contains(index) ? FieldKind(matching: fields[index].kind) : .text },
            set: { newKind in
                guard fields.indices.contains(index) else { return }
                fields[index].kind = newKind.defaultValue
                onCommit()
            }
        )
    }

    private func field(_ index: Int, _ keyPath: WritableKeyPath<FormField, String>) -> Binding<String> {
        Binding(
            get: { fields.indices.contains(index) ? fields[index][keyPath: keyPath] : "" },
            set: { if fields.indices.contains(index) { fields[index][keyPath: keyPath] = $0 } }
        )
    }

    /// A binding onto the default value of a field whose kind carries one.
    private func defaultBinding(_ index: Int, current: String,
                                _ rebuild: @escaping (String) -> FormField.Kind) -> Binding<String> {
        Binding(
            get: { current },
            set: { if fields.indices.contains(index) { fields[index].kind = rebuild($0) } }
        )
    }

    /// `field1`, `field2`, … — the first name this form has not used.
    private func nextFieldName() -> String {
        TokenSerialiser.uniqueName(prefix: "field", taken: Set(fields.map(\.name)))
    }
}
