#if canImport(UIKit)
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import StorybookProtocol
import StorybookRuntime

/// Controls generated from the story's argTypes. Edits go through the
/// store, so the agent socket sees them too (and vice versa).
struct ControlsPanel: View {
    let store: StoryStore
    @State private var error: String?

    var body: some View {
        if let story = store.selected, let args = try? store.args(for: story.id) {
            Form {
                ForEach(story.description.argOrder, id: \.self) { name in
                    if let argType = story.description.argTypes[name] {
                        ArgControlRow(argType: argType, value: args[name] ?? .null) { newValue in
                            do {
                                try store.updateArgs(story.id, patch: .object([name: newValue]))
                                error = nil
                            } catch {
                                self.error = "\(error)"
                            }
                        }
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Reset args") { try? store.resetArgs(story.id) }
            }
            .contentMargins(.top, 4, for: .scrollContent)
        } else {
            Text("Select a story").foregroundStyle(.secondary).frame(maxHeight: .infinity)
        }
    }
}

struct ArgControlRow: View {
    let argType: ArgType
    let value: JSONValue
    let onChange: (JSONValue) -> Void

    var body: some View {
        HStack {
            if !argType.type.required, value == .null {
                LabeledContent(argType.name) {
                    Button("Set") { onChange(defaultValue) }
                }
            } else {
                control
                if !argType.type.required {
                    Button { onChange(.null) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .help(argType.description ?? "")
    }

    @ViewBuilder private var control: some View {
        let name = argType.name
        if let action = argType.action {
            LabeledContent(name) { Text("action \"\(action)\"").font(.caption.monospaced()).foregroundStyle(.secondary) }
        } else {
            switch argType.control?.type {
            case "boolean":
                Toggle(name, isOn: Binding(get: { value == .bool(true) }, set: { onChange(.bool($0)) }))
            case "text":
                LabeledContent(name) {
                    TextField(name, text: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) }),
                              axis: argType.control?.multiline == true ? .vertical : .horizontal)
                        .multilineTextAlignment(.trailing)
                }
            case "range":
                let spec = argType.control!
                VStack(alignment: .leading) {
                    LabeledContent(name) { Text(number.formatted()).monospacedDigit() }
                    Slider(value: Binding(get: { number }, set: { onChange(.number($0)) }),
                           in: (spec.min ?? 0)...(spec.max ?? 100), step: spec.step ?? 1)
                }
            case "number":
                LabeledContent(name) {
                    HStack {
                        TextField(name, value: Binding(get: { number }, set: { onChange(.number($0)) }), format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                        Stepper(name, value: Binding(get: { number }, set: { onChange(.number($0)) }),
                                step: argType.control?.step ?? 1).labelsHidden()
                    }
                }
            case "select":
                Picker(name, selection: Binding(get: { value.stringValue ?? "" }, set: { onChange(.string($0)) })) {
                    ForEach(argType.options ?? [], id: \.self) { Text($0).tag($0) }
                }
            case "color":
                ColorPicker(name, selection: Binding(get: { Color(hex: value.stringValue ?? "#000000") },
                                                     set: { onChange(.string($0.hexString)) }))
            default:
                LabeledContent(name) { JSONField(value: value, onChange: onChange) }
            }
        }
    }

    private var number: Double {
        if case .number(let number) = value { return number }
        return 0
    }

    private var defaultValue: JSONValue {
        switch argType.control?.type {
        case "boolean": .bool(false)
        case "text": .string("")
        case "number", "range": .number(argType.control?.min ?? 0)
        case "select": argType.options?.first.map(JSONValue.string) ?? .null
        case "color": .string("#000000")
        default: .object([:])
        }
    }
}

/// Raw JSON editing for args without a dedicated control.
struct JSONField: View {
    let value: JSONValue
    let onChange: (JSONValue) -> Void
    @State private var text = ""

    var body: some View {
        TextField("JSON", text: $text)
            .font(.caption.monospaced())
            .multilineTextAlignment(.trailing)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { text = Self.format(value) }
            .onSubmit {
                if let data = text.data(using: .utf8), let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    onChange(parsed)
                }
            }
    }

    static func format(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension Color {
    init(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6 { digits += "FF" }
        let value = UInt64(digits, radix: 16) ?? 0xFF
        self.init(.sRGB, red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                  blue: Double((value >> 8) & 0xFF) / 255, opacity: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let bytes = [r, g, b, a].map { Int(($0 * 255).rounded()).clamped(to: 0...255) }
        let rgb = String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        return bytes[3] == 255 ? rgb : rgb + String(format: "%02X", bytes[3])
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
