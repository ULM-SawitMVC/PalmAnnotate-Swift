import PalmCore
import SwiftUI

struct AnnotationEditor: View {
    let id: String
    let store: PackageStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var document: TreeDocument?
    @State private var images: [Int: UIImage] = [:]
    @State private var side = 0
    @State private var selected: BoxRef?
    @State private var pendingLink: BoxRef?
    @State private var tool = CanvasTool.select
    @State private var showMeasurements = false
    @State private var showResults = false
    @State private var error: String?
    @State private var status: String?
    @State private var saving = false
    @State private var clockwise = true

    var body: some View {
        Group {
            if let document {
                editor(document)
            } else if error == nil {
                ProgressView("Memuat sampel…")
            }
        }
        .navigationTitle(id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Hasil", systemImage: "chart.bar") { showResults = true }.disabled(document == nil || saving)
            }
        }
        .sheet(isPresented: $showMeasurements) {
            if let document, let selected, let box = document.annotation(selected) {
                MeasurementForm(value: box.measurements) { value in
                    persist { $0.setMeasurements(selected, value) }
                }
            }
        }
        .sheet(isPresented: $showResults, onDismiss: { Task { await load() } }) {
            if let document { ResultsView(document: document, store: store) }
        }
        .task { await load() }
        .modifier(ErrorAlert(message: $error))
        .navigationBarBackButtonHidden(saving)
    }

    private func editor(_ tree: TreeDocument) -> some View {
        Group {
            if verticalSizeClass == .compact {
                HStack(alignment: .top, spacing: 16) {
                    photoPanel(tree).frame(maxWidth: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            editorTools(tree)
                            editorActions(tree)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: 360)
                }
                .padding(.horizontal)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        editorTools(tree)
                        photoPanel(tree)
                        editorActions(tree)
                    }
                    .padding()
                    .frame(maxWidth: 960)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .disabled(saving)
    }

    @ViewBuilder
    private func photoPanel(_ tree: TreeDocument) -> some View {
        if let image = images[side], tree.sides.indices.contains(side) {
            canvas(tree, image: image)
        }
    }

    @ViewBuilder
    private func editorTools(_ tree: TreeDocument) -> some View {
        sidePicker(tree)
        if let pendingLink {
            Label("Pilih kotak dari sisi yang bersebelahan dengan Foto \(pendingLink.side + 1).", systemImage: "link")
            Button("Batalkan tautan") { self.pendingLink = nil }
        }
        Picker("Alat anotasi", selection: $tool) {
            ForEach(CanvasTool.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        if tree.run.type == .multiside {
            Toggle("Arah tangkap searah jarum jam", isOn: $clockwise)
        }
    }

    @ViewBuilder
    private func editorActions(_ tree: TreeDocument) -> some View {
        if let selected, let box = tree.annotation(selected) {
            selectionActions(tree, selected: selected, box: box)
        }
        if let status {
            Text(status).foregroundStyle(.secondary).accessibilityIdentifier("save-status")
        }
        if tree.run.type == .bunchWeight, let error = tree.completionError {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
        }
        Button("Selesaikan sampel", systemImage: "checkmark.circle") {
            persist(markComplete: true) { _ in }
        }
        .buttonStyle(.borderedProminent)
        .disabled(tree.completionError != nil)
    }

    private func sidePicker(_ tree: TreeDocument) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(tree.sides) { item in
                    Button("Foto \(item.id + 1)") {
                        side = item.id
                        selected = nil
                        tool = .select
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(side == item.id ? .accentColor : .secondary)
                }
            }
        }
    }

    private func canvas(_ tree: TreeDocument, image: UIImage) -> some View {
        let numbers = Dictionary(uniqueKeysWithValues: tree.clusters.enumerated().flatMap { index, cluster in
            cluster.filter { $0.side == side }.map { ($0.box, index + 1) }
        })
        return AnnotationCanvas(
            image: image, side: tree.sides[side], selected: selected?.box, tool: tool,
            labels: numbers, weighted: tree.run.type == .bunchWeight,
            height: verticalSizeClass == .compact ? 218 : 275,
            onSelect: { box in selected = box.map { BoxRef(side: side, box: $0) } },
            onDraw: { rect in
                persist { tree in selected = tree.addBox(side: side, rect: rect) }
            },
            onChange: { id, rect in
                persist { $0.changeBox(BoxRef(side: side, box: id), rect: rect) }
            })
            .id(side)
    }

    private func selectionActions(_ tree: TreeDocument, selected: BoxRef, box: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let number = tree.clusters.firstIndex { $0.contains(selected) }.map { $0 + 1 } ?? 0
            Text("Tandan \(number)").font(.headline)
            if tree.run.type == .bunchWeight {
                if let weight = box.measurements.weightKg {
                    Text("\(weight.formatted()) kg")
                }
                Button("Ukuran tandan", systemImage: "scalemass") { showMeasurements = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Picker("Kelas kematangan", selection: Binding(
                    get: { box.ripeness },
                    set: { value in persist { $0.setRipeness(selected, ripeness: value) } }
                )) {
                    ForEach(Ripeness.allCases) { value in
                        Text(value == .unassigned ? "Belum diberi kelas" : value.label).tag(value)
                    }
                }
                .pickerStyle(.menu)
            }
            if let pendingLink {
                Button("Konfirmasi tautan", systemImage: "link") { connect(source: pendingLink, target: selected) }
                    .disabled(!tree.canLink(pendingLink, selected))
            } else if tree.sides.count > 1 {
                Button("Tautkan ke foto lain", systemImage: "link") {
                    pendingLink = selected
                    tool = .select
                }
                let suggestions = tree.suggestedLinks(from: selected, clockwise: clockwise)
                if !suggestions.isEmpty {
                    Menu("Saran tautan", systemImage: "link.badge.plus") {
                        ForEach(suggestions, id: \.self) { candidate in
                            Button("Foto \(candidate.side + 1) · Tandan \(numberOf(candidate, tree: tree))") {
                                pendingLink = selected
                                self.selected = candidate
                                side = candidate.side
                                tool = .select
                            }
                        }
                    }
                }
            }
            ForEach(tree.links.filter { $0.a == selected || $0.b == selected }) { link in
                let other = link.a == selected ? link.b : link.a
                Button("Lepas tautan dari foto \(other.side + 1)", systemImage: "link.badge.plus") {
                    persist { $0.unlink(link.id) }
                }
            }
            Button("Hapus kotak", systemImage: "trash", role: .destructive) {
                persist { $0.deleteBox(selected); self.selected = nil }
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberOf(_ ref: BoxRef, tree: TreeDocument) -> Int {
        tree.clusters.firstIndex { $0.contains(ref) }.map { $0 + 1 } ?? 0
    }

    private func connect(source: BoxRef, target: BoxRef) {
        persistWithStatus { tree in
            let replaced = tree.link(source, target)
            pendingLink = nil
            if replaced { return "Tersimpan. Ukuran tandan mengikuti kotak sumber." }
            return nil
        }
    }

    private func persist(markComplete: Bool = false, _ edit: (inout TreeDocument) -> Void) {
        persistWithStatus(markComplete: markComplete) { tree in
            edit(&tree)
            return nil
        }
    }

    private func persistWithStatus(markComplete: Bool = false, _ edit: (inout TreeDocument) -> String?) {
        guard !saving, var updated = document else { return }
        let message = edit(&updated)
        saving = true
        Task {
            defer { saving = false }
            do {
                document = try await store.save(updated, markComplete: markComplete)
                status = message ?? (markComplete ? "Sampel selesai dan tersimpan." : "Perubahan tersimpan.")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        do {
            let tree = try await store.tree(id: id)
            var decoded: [Int: UIImage] = [:]
            for side in tree.sides {
                let url = await store.photoURL(treeID: id, side: side.id)
                decoded[side.id] = UIImage(contentsOfFile: url.path)
            }
            images = decoded
            document = tree
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private enum CanvasTool: String, CaseIterable, Identifiable {
    case select, draw, move, resize
    var id: Self { self }
    var title: String {
        switch self {
        case .select: "Pilih kotak"
        case .draw: "Gambar kotak"
        case .move: "Geser kotak"
        case .resize: "Ubah ukuran kotak"
        }
    }
}

private struct AnnotationCanvas: View {
    let image: UIImage
    let side: CaptureSide
    let selected: String?
    let tool: CanvasTool
    let labels: [String: Int]
    let weighted: Bool
    let height: CGFloat
    let onSelect: (String?) -> Void
    let onDraw: (PixelBox) -> Void
    let onChange: (String, PixelBox) -> Void
    @State private var preview: PixelBox?
    @State private var zoom = false

    var body: some View {
        VStack(alignment: .leading) {
            GeometryReader { proxy in
                let naturalScale = min(proxy.size.width / CGFloat(side.width), proxy.size.height / CGFloat(side.height))
                let scale = naturalScale * (zoom ? 2 : 1)
                if zoom {
                    ScrollView([.horizontal, .vertical]) {
                        picture(scale: scale)
                    }
                    .defaultScrollAnchor(.center)
                } else {
                    picture(scale: scale).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)
            Toggle("Perbesar foto", isOn: $zoom).toggleStyle(.button)
        }
    }

    private func picture(scale: CGFloat) -> some View {
        let width = CGFloat(side.width) * scale
        let height = CGFloat(side.height) * scale
        return Image(uiImage: image).resizable()
            .frame(width: width, height: height)
            .overlay {
                Canvas { context, _ in
                    for box in side.annotations {
                        let active = box.id == selected
                        let position = active && tool != .draw ? preview ?? box.rect : box.rect
                        let rect = CGRect(x: CGFloat(position.x1) * scale, y: CGFloat(position.y1) * scale,
                                          width: CGFloat(position.x2 - position.x1) * scale,
                                          height: CGFloat(position.y2 - position.y1) * scale)
                        let color = active ? Color.yellow : color(for: box.ripeness)
                        context.stroke(Path(rect), with: .color(color), lineWidth: active ? 3 : 2)
                        if let number = labels[box.id] {
                            let label = weighted || box.ripeness == .unassigned ? "\(number)" : "\(number) · \(box.ripeness.label)"
                            context.draw(Text(label).font(.caption.bold()).foregroundStyle(.white),
                                         at: CGPoint(x: rect.minX + 3, y: rect.minY + 2), anchor: .topLeading)
                        }
                    }
                    if tool == .draw, let preview {
                        let rect = CGRect(x: CGFloat(preview.x1) * scale, y: CGFloat(preview.y1) * scale,
                                          width: CGFloat(preview.x2 - preview.x1) * scale,
                                          height: CGFloat(preview.y2 - preview.y1) * scale)
                        context.stroke(Path(rect), with: .color(.yellow), lineWidth: 3)
                    }
                }
            }
            .contentShape(.rect)
            .onTapGesture { point in
                guard tool == .select else { return }
                let x = Float(point.x / scale)
                let y = Float(point.y / scale)
                let boxes = side.annotations.filter { x >= $0.rect.x1 && x <= $0.rect.x2 && y >= $0.rect.y1 && y <= $0.rect.y2 }
                onSelect(boxes.min { area($0.rect) < area($1.rect) }?.id)
            }
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { gesture in preview = drag(gesture, scale: scale) }
                .onEnded { gesture in
                    defer { preview = nil }
                    guard let rect = drag(gesture, scale: scale) else { return }
                    if tool == .draw { onDraw(rect) }
                    else if let selected { onChange(selected, rect) }
                }, including: tool == .select ? .none : .all)
            .accessibilityLabel("Foto dengan kotak anotasi")
            .accessibilityIdentifier("annotation-photo")
    }

    private func area(_ box: PixelBox) -> Float { (box.x2 - box.x1) * (box.y2 - box.y1) }

    private func drag(_ gesture: DragGesture.Value, scale: CGFloat) -> PixelBox? {
        let x = Float(gesture.location.x / scale)
        let y = Float(gesture.location.y / scale)
        if tool == .draw {
            let startX = Float(gesture.startLocation.x / scale)
            let startY = Float(gesture.startLocation.y / scale)
            return PixelBox(x1: min(x, startX), y1: min(y, startY), x2: max(x, startX), y2: max(y, startY))
        }
        guard tool != .select, let box = side.annotations.first(where: { $0.id == selected })?.rect else { return nil }
        let dx = Float(gesture.translation.width / scale)
        let dy = Float(gesture.translation.height / scale)
        if tool == .move {
            let dx = min(max(dx, -box.x1), Float(side.width) - box.x2)
            let dy = min(max(dy, -box.y1), Float(side.height) - box.y2)
            return PixelBox(x1: box.x1 + dx, y1: box.y1 + dy, x2: box.x2 + dx, y2: box.y2 + dy)
        }
        return PixelBox(x1: box.x1, y1: box.y1, x2: max(box.x1 + 1, box.x2 + dx), y2: max(box.y1 + 1, box.y2 + dy))
    }

    private func color(for ripeness: Ripeness) -> Color {
        switch ripeness {
        case .unassigned: .white
        case .b1: .blue
        case .b2: .red
        case .b3: .orange
        case .b4: .purple
        }
    }
}

private struct MeasurementForm: View {
    let value: Measurements
    let onSave: (Measurements) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var weight = ""
    @State private var height = ""
    @State private var circumference = ""
    @State private var notes = ""
    @State private var validation: String?

    var body: some View {
        NavigationStack {
            Form {
                if let validation { Text(validation).foregroundStyle(.red) }
                TextField("Berat (kg)", text: $weight).keyboardType(.decimalPad)
                TextField("Tinggi (cm, opsional)", text: $height).keyboardType(.decimalPad)
                TextField("Lingkar (cm, opsional)", text: $circumference).keyboardType(.decimalPad)
                TextField("Catatan (opsional)", text: $notes, axis: .vertical)
            }
            .navigationTitle("Ukuran tandan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Batal") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Terapkan", action: apply) }
            }
            .onAppear {
                weight = value.weightKg.map { String($0) } ?? ""
                height = value.heightCm.map { String($0) } ?? ""
                circumference = value.circumferenceCm.map { String($0) } ?? ""
                notes = value.notes ?? ""
            }
        }
    }

    private func apply() {
        func parse(_ input: String) -> Double? {
            Double(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        let value = Measurements(weightKg: parse(weight), heightCm: parse(height), circumferenceCm: parse(circumference), notes: notes)
        if !height.trimmingCharacters(in: .whitespaces).isEmpty && value.heightCm == nil {
            validation = "Masukkan tinggi yang valid."
        } else if !circumference.trimmingCharacters(in: .whitespaces).isEmpty && value.circumferenceCm == nil {
            validation = "Masukkan lingkar yang valid."
        } else if let error = value.validationError {
            validation = error
        } else {
            onSave(value)
            dismiss()
        }
    }
}
