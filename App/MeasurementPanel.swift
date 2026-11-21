import PalmCore
import SwiftUI

enum MeasurementField: Hashable {
    case weight, height, circumference, notes
}

struct MeasurementDraft: Equatable {
    var weight = ""
    var height = ""
    var circumference = ""
    var notes = ""
    var optionalOpen = false
    var error: String?

    init() {}

    init(_ value: Measurements, optionalOpen: Bool = false) {
        weight = value.weightKg.map { String($0) } ?? ""
        height = value.heightCm.map { String($0) } ?? ""
        circumference = value.circumferenceCm.map { String($0) } ?? ""
        notes = value.notes ?? ""
        self.optionalOpen = optionalOpen
    }

    var filledOptionalCount: Int {
        [height, circumference, notes].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    func parsed() -> Result<Measurements, Measurements.InputError> {
        do {
            return .success(try Measurements.parse(weight: weight, height: height, circumference: circumference, notes: notes))
        } catch let error as Measurements.InputError {
            return .failure(error)
        } catch {
            return .failure(Measurements.InputError(message: error.localizedDescription))
        }
    }
}

struct MeasurementFields: View {
    let number: Int
    @Binding var draft: MeasurementDraft
    var focus: FocusState<MeasurementField?>.Binding
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tandan \(number)").font(.headline)
                Spacer()
                Button("Tutup ukuran", systemImage: "xmark.circle.fill", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.large)
                    .accessibilityIdentifier("measurement-close")
            }
            TextField("Berat (kg) *", text: $draft.weight)
                .keyboardType(.decimalPad)
                .focused(focus, equals: .weight)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("measurement-weight")
                .onChange(of: draft.weight) { draft.error = nil }
            Button {
                withAnimation(.snappy) { draft.optionalOpen.toggle() }
            } label: {
                HStack {
                    Image(systemName: draft.optionalOpen ? "chevron.up" : "chevron.down")
                    Text("Detail opsional")
                    Spacer()
                    if draft.filledOptionalCount > 0 {
                        Text("\(draft.filledOptionalCount) terisi").foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("measurement-optional-toggle")
            .accessibilityValue(draft.optionalOpen ? "Terbuka" : "Tertutup")
            if draft.optionalOpen {
                TextField("Tinggi (cm), opsional", text: $draft.height)
                    .keyboardType(.decimalPad)
                    .focused(focus, equals: .height)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("measurement-height")
                    .onChange(of: draft.height) { draft.error = nil }
                TextField("Lingkar (cm), opsional", text: $draft.circumference)
                    .keyboardType(.decimalPad)
                    .focused(focus, equals: .circumference)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("measurement-circumference")
                    .onChange(of: draft.circumference) { draft.error = nil }
                TextField("Catatan tambahan, opsional", text: $draft.notes, axis: .vertical)
                    .lineLimit(1...3)
                    .focused(focus, equals: .notes)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("measurement-notes")
                    .onChange(of: draft.notes) { draft.error = nil }
            }
        }
    }
}

struct MeasurementApplyBar: View {
    let error: String?
    let disabled: Bool
    let keyboardOpen: Bool
    let onHideKeyboard: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("measurement-error")
            }
            HStack(spacing: 8) {
                if keyboardOpen {
                    Button("Tutup papan ketik", systemImage: "keyboard.chevron.compact.down", action: onHideKeyboard)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("measurement-hide-keyboard")
                }
                Button("Terapkan", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(disabled)
                    .accessibilityIdentifier("measurement-apply")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
