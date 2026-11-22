import PalmCore
import SwiftUI

struct BoxCoordinateTarget: Identifiable {
    let id = UUID()
    let side: Int
    let width: Int
    let height: Int
    let ref: BoxRef?
    let rect: PixelBox?

    init(photo: CaptureSide, ref: BoxRef? = nil, rect: PixelBox? = nil) {
        side = photo.id
        width = photo.width
        height = photo.height
        self.ref = ref
        self.rect = rect
    }
}

struct BoxCoordinateForm: View {
    let width: Int
    let height: Int
    let title: String
    let onSave: (PixelBox) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var left: String
    @State private var top: String
    @State private var right: String
    @State private var bottom: String
    @State private var error: String?

    init(width: Int, height: Int, initial: PixelBox?, onSave: @escaping (PixelBox) -> Void) {
        self.width = width
        self.height = height
        self.onSave = onSave
        title = initial == nil ? "Tambah kotak" : "Ubah koordinat kotak"
        _left = State(initialValue: initial.map { String($0.x1) } ?? "")
        _top = State(initialValue: initial.map { String($0.y1) } ?? "")
        _right = State(initialValue: initial.map { String($0.x2) } ?? "")
        _bottom = State(initialValue: initial.map { String($0.y2) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coordinate("Kiri (X)", value: $left)
                    coordinate("Atas (Y)", value: $top)
                    coordinate("Kanan (X)", value: $right)
                    coordinate("Bawah (Y)", value: $bottom)
                } footer: {
                    Text("Koordinat dalam piksel, dihitung dari sudut kiri atas foto. X dari 0 sampai \(width), Y dari 0 sampai \(height).")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                Button("Simpan kotak", action: save)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Batal") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Simpan", action: save)
                }
            }
        }
    }

    private func coordinate(_ label: String, value: Binding<String>) -> some View {
        LabeledContent {
            TextField(label, text: value, prompt: Text("Piksel"))
                .labelsHidden()
                .accessibilityLabel(label)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .onChange(of: value.wrappedValue) { _, _ in error = nil }
        } label: {
            Text(label).accessibilityHidden(true)
        }
    }

    private func save() {
        func parse(_ value: String) -> Float? {
            Float(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        guard let x1 = parse(left), let y1 = parse(top), let x2 = parse(right), let y2 = parse(bottom) else {
            showError("Isi keempat koordinat dengan angka.")
            return
        }
        let rect = PixelBox(x1: x1, y1: y1, x2: x2, y2: y2)
        guard rect.clipped(width: width, height: height) == rect else {
            showError("Kotak harus berada di dalam foto dengan lebar dan tinggi minimal 1 piksel.")
            return
        }
        onSave(rect)
        dismiss()
    }

    private func showError(_ message: String) {
        error = message
        AccessibilityNotification.Announcement(message).post()
    }
}
