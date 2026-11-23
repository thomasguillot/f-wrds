import SwiftUI
import WrdsKit

/// One row per `FormField`, submitted with the answers keyed `"<variableName>.<fieldName>"` — the
/// same spelling `RenderContext.formAnswers` and `{{variable.field}}` tokens use.
///
/// Field kinds map onto controls one for one: `text` is a `TextField`, `multiline` a `TextEditor`
/// roughly four lines tall, `choice` a menu-style `Picker`. Every field starts out holding its own
/// default — `FormField.Kind`'s associated value for `text`/`multiline`, the first option for
/// `choice` — so submitting without touching anything is a valid answer, not an empty one.
///
/// ## Submitting
///
/// Plain Return submits from a focused `TextField` through SwiftUI's own `.onSubmit(_:)` — the
/// standard mechanism for "press Return in a form field to submit the form" — which a focused
/// `TextEditor` deliberately does not participate in: Return there inserts a newline, the same as it
/// would editing any other multi-line text. ⌘Return is the one shortcut that always submits
/// regardless of what has focus, bound to the panel's own default-styled button rather than routed
/// through `.onSubmit`, so it reaches past a focused `TextEditor`'s own handling of plain Return the
/// same way ⌘Return-to-send does in Mail or Messages.
///
/// A focused `Picker` is the one gap this leaves: a menu-style picker does not participate in
/// `.onSubmit`, so plain Return while a choice field has focus opens its menu rather than submitting
/// the form. The Submit button, Tab to another field, or ⌘Return all still work from there.
struct FormPanelView: View {
    let variable: Variable
    let fields: [FormField]
    let onSubmit: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var values: [UUID: String]
    @FocusState private var focusedFieldID: UUID?

    init(
        variable: Variable, fields: [FormField], onSubmit: @escaping ([String: String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.variable = variable
        self.fields = fields
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        var initial: [UUID: String] = [:]
        for field in fields {
            initial[field.id] = Self.defaultValue(for: field.kind)
        }
        _values = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields) { field in
                    row(for: field)
                }
            }
            buttons
        }
        .padding(16)
        .frame(width: 320)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onSubmit(submit)
        .onExitCommand(perform: onCancel)
        .onAppear {
            focusedFieldID = fields.first?.id
        }
    }

    @ViewBuilder
    private func row(for field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !field.label.isEmpty {
                Text(field.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            control(for: field)
        }
    }

    @ViewBuilder
    private func control(for field: FormField) -> some View {
        switch field.kind {
        case .text:
            TextField("", text: binding(for: field))
                .textFieldStyle(.roundedBorder)
                .focused($focusedFieldID, equals: field.id)
        case .multiline:
            TextEditor(text: binding(for: field))
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 76)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.3))
                )
                .focused($focusedFieldID, equals: field.id)
        case .choice(let options):
            Picker("", selection: binding(for: field)) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focused($focusedFieldID, equals: field.id)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Submit", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
        }
    }

    private func binding(for field: FormField) -> Binding<String> {
        Binding(
            get: { values[field.id] ?? "" },
            set: { values[field.id] = $0 }
        )
    }

    private func submit() {
        var answers: [String: String] = [:]
        for field in fields {
            answers["\(variable.name).\(field.name)"] = values[field.id] ?? ""
        }
        onSubmit(answers)
    }

    private static func defaultValue(for kind: FormField.Kind) -> String {
        switch kind {
        case .text(let defaultValue): return defaultValue
        case .multiline(let defaultValue): return defaultValue
        case .choice(let options): return options.first ?? ""
        }
    }
}
