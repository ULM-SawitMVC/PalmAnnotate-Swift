import PalmCore
import SwiftUI

struct AnnotationEditor: View {
    let id: String
    let store: PackageStore
    var onNext: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var document: TreeDocument?
    @State private var cache = SideImageCache()
    @State private var unreadable: Set<Int> = []
    @State private var side = 0
    @State private var pagerSide: Int?
    @State private var selected: BoxRef?
    @State private var pendingLink: BoxRef?
    @State private var mode = EditorMode.review
    @State private var drawing = false
    @State private var showBoxes = true
    @State private var reverseSwipe: Bool?
    @State private var viewports: [Int: Viewport] = [:]
    @State private var showResults = false
    @State private var showSuggestions = false
    @State private var showResultsAfterDedup = false
    @State private var showMismatch = false
    @State private var boxCoordinates: BoxCoordinateTarget?
    @State private var draft = MeasurementDraft()
    @FocusState private var field: MeasurementField?
    @State private var wide = UIScreen.main.bounds.width > UIScreen.main.bounds.height
    @State private var toast: String?
    @State private var toastToken = UUID()
    @State private var error: String?
    @State private var status: String?
    @State private var savedPulse = false
    @State private var saving = false
    @State private var detecting = false
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
            ToolbarItem(placement: .topBarLeading) {
                Button(action: exit) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward").fontWeight(.semibold)
                        Text("Kembali")
                    }
                }
                .disabled(saving || detecting)
                .accessibilityIdentifier("editor-back")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Deteksi", systemImage: "sparkles", action: detect)
                    .disabled(document == nil || saving || detecting)
                Button("Hasil", systemImage: "chart.bar") { showResults = true }
                    .disabled(document == nil || saving || detecting)
            }
        }
        .sheet(isPresented: $showResults, onDismiss: { Task { await load() } }) {
            if let document { ResultsView(document: document, store: store) }
        }
        .sheet(isPresented: $showSuggestions, onDismiss: {
            guard showResultsAfterDedup else { return }
            showResultsAfterDedup = false
            showResults = true
        }) {
            if let document {
                DedupSheet(document: document, clockwise: $clockwise, busy: saving,
                           images: cache, loadImage: { await loadImage($0) },
                           onAccept: { items in
                    persistWithStatus { tree in
                        var accepted = 0
                        for item in items where tree.canLink(item.a, item.b) {
                            tree.link(item.a, item.b)
                            accepted += 1
                        }
                        return "\(accepted) tautan tersimpan."
                    }
                }, onRemove: { id in
                    persistWithStatus { $0.unlink(id); return "Tautan dilepas." }
                }, onCompute: { choices in
                    persistWithStatus(then: {
                        showResultsAfterDedup = true
                        showSuggestions = false
                    }) { tree in
                        tree.resolveClassMismatches(choices)
                        return "Tautan dan kelas tersimpan."
                    }
                })
            }
        }
        .sheet(isPresented: $showMismatch) {
            if let document {
                MismatchResolutionSheet(mismatches: document.classMismatches(), applyTitle: "Terapkan") { choices in
                    persistWithStatus { tree in
                        tree.resolveClassMismatches(choices)
                        return "Kelas tandan diseragamkan."
                    }
                }
            }
        }
        .sheet(item: $boxCoordinates) { target in
            BoxCoordinateForm(width: target.width, height: target.height, initial: target.rect) { rect in
                drawing = false
                if let ref = target.ref {
                    persist { $0.changeBox(ref, rect: rect) }
                } else {
                    addBox(rect, side: target.side)
                }
            }
        }
        .task { await load() }
        .modifier(ErrorAlert(message: $error))
        .navigationBarBackButtonHidden(true)
        .onChange(of: selected) { _, value in
            guard let document, let value, document.run.type == .bunchWeight,
                  let box = document.annotation(value) else { return }
            draft = MeasurementDraft(box.measurements)
        }
        .onChange(of: selectedMeasurements) { _, value in
            guard let value else { return }
            draft = MeasurementDraft(value, optionalOpen: draft.optionalOpen)
        }
        .onChange(of: side) { _, value in
            Task {
                await loadImage(value)
                await loadImage(value + 1)
                await loadImage(value - 1)
            }
        }
    }

    private var selectedMeasurements: Measurements? {
        guard let document, document.run.type == .bunchWeight, let selected else { return nil }
        return document.annotation(selected)?.measurements
    }

    // MARK: Layout

    private func editor(_ tree: TreeDocument) -> some View {
        let panel = measurementTarget(tree)
        return GeometryReader { proxy in
            if wide {
                HStack(alignment: .top, spacing: 12) {
                    photoPanel(tree)
                    controlsColumn(tree, panel: panel)
                        .frame(width: min(420, proxy.size.width * (dynamicTypeSize.isAccessibilitySize ? 0.55 : 0.4)))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 8) {
                    photoPanel(tree)
                        .frame(height: portraitPhotoHeight(in: proxy.size.height))
                        .padding(.horizontal)
                    controlsColumn(tree, panel: panel)
                        .frame(maxWidth: 760)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .disabled(saving)
        .background {
            GeometryReader { probe in
                Color.clear
                    .onAppear { wide = probe.size.width > probe.size.height }
                    .onChange(of: probe.size) { _, size in wide = size.width > size.height }
            }
            .ignoresSafeArea(.keyboard)
        }
    }

    private func measurementTarget(_ tree: TreeDocument) -> BoxRef? {
        guard tree.run.type == .bunchWeight, let selected, pendingLink == nil, tree.annotation(selected) != nil else { return nil }
        return selected
    }

    private func controlsColumn(_ tree: TreeDocument, panel: BoxRef?) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                controls(tree, panel: panel).padding(.vertical, 8).padding(.horizontal, isLandscape ? 0 : 16)
            }
            .scrollDismissesKeyboard(.never)
            if panel != nil {
                MeasurementApplyBar(error: draft.error, disabled: saving || detecting, keyboardOpen: field != nil,
                                    onHideKeyboard: { field = nil }, onApply: applyMeasurements)
            }
        }
    }

    private var isLandscape: Bool { wide }

    private func portraitPhotoHeight(in height: CGFloat) -> CGFloat {
        if dynamicTypeSize.isAccessibilitySize || field != nil {
            return max(120, height * 0.3)
        }
        return max(220, height * 0.55)
    }

    private func photoPanel(_ tree: TreeDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sideHeader(tree)
            pager(tree)
                .overlay(alignment: .topLeading) { countBadge(tree) }
                .overlay(alignment: .topTrailing) { zoomControls }
                .overlay(alignment: .center) { drawPrompt(tree) }
                .overlay(alignment: .bottom) { photoFooter(tree) }
        }
    }

    private func sideHeader(_ tree: TreeDocument) -> some View {
        HStack(spacing: 8) {
            Text("Foto \(side + 1) / \(tree.sides.count)")
                .font(.headline.monospacedDigit())
                .accessibilityIdentifier("side-counter")
            if tree.sides.count > 1 {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(tree.sides) { item in
                            Button("Foto \(item.id + 1)") { show(side: item.id, animated: true) }
                                .buttonStyle(.borderedProminent)
                                .tint(side == item.id ? .accentColor : .secondary)
                                .accessibilityAddTraits(side == item.id ? .isSelected : [])
                                .frame(minHeight: 44)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func pager(_ tree: TreeDocument) -> some View {
        let reversed = reverseSwipe ?? (tree.run.type == .multiside)
        let order = reversed ? Array(tree.sides.reversed()) : tree.sides
        let zoomed = (viewports[side]?.zoom ?? 1) > 1.001
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(order) { item in
                    page(tree, item)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerSide)
        .scrollDisabled(mode == .edit || zoomed || tree.sides.count < 2)
        .scrollIndicators(.hidden)
        .background(.black)
        .clipShape(.rect(cornerRadius: 10))
        .onChange(of: pagerSide) { _, value in
            if let value, value != side { show(side: value, animated: false) }
        }
        .accessibilityIdentifier("side-pager")
    }

    @ViewBuilder
    private func page(_ tree: TreeDocument, _ item: CaptureSide) -> some View {
        Group {
            if let image = cache.image(item.id) {
                canvas(tree, item, image)
            } else if unreadable.contains(item.id) {
                ContentUnavailableView("Foto tidak dapat dibaca", systemImage: "photo")
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) { await loadImage(item.id) }
    }

    private func canvas(_ tree: TreeDocument, _ item: CaptureSide, _ image: UIImage) -> some View {
        AnnotationCanvas(
                image: image, side: item, selected: item.id == side ? selected?.box : nil,
                linkSource: pendingLink?.side == item.id ? pendingLink?.box : nil,
                editing: mode == .edit, drawing: drawing && item.id == side, showBoxes: showBoxes,
                labels: labels(tree, side: item.id), linkGroups: linkGroups(tree, side: item.id),
                weighted: tree.run.type == .bunchWeight,
                viewport: Binding(get: { viewports[item.id] ?? Viewport() }, set: { viewports[item.id] = $0 }),
                onTap: { tap(box: $0, side: item.id) },
                onGrab: { selected = BoxRef(side: item.id, box: $0) },
                onDraw: { addBox($0, side: item.id) },
                onChange: { box, rect in persist { $0.changeBox(BoxRef(side: item.id, box: box), rect: rect) } })
            .accessibilityIdentifier(item.id == side ? "annotation-photo" : "annotation-photo-\(item.id + 1)")
    }

    private func countBadge(_ tree: TreeDocument) -> some View {
        let boxes = tree.sides[side].annotations
        let linked = Set(tree.links.flatMap { [$0.a, $0.b] }.filter { $0.side == side }.map(\.box)).count
        let unassigned = tree.run.type == .multiside ? boxes.filter { $0.ripeness == .unassigned }.count : 0
        var parts = ["\(boxes.count) kotak"]
        if unassigned > 0 { parts.append("\(unassigned) belum berkelas") }
        if linked > 0 { parts.append("\(linked) tertaut") }
        return Text(parts.joined(separator: " · "))
            .font(.caption.bold())
            .foregroundStyle(unassigned > 0 ? .yellow : .white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityIdentifier("box-count")
    }

    private var zoomControls: some View {
        let scale = viewports[side]?.zoom ?? 1
        return VStack(spacing: 6) {
            Button("Perbesar", systemImage: "plus.magnifyingglass") { zoom(by: 1.6) }
                .disabled(scale >= Viewport.maxZoom)
            Button("Perkecil", systemImage: "minus.magnifyingglass") { zoom(by: 1 / 1.6) }
                .disabled(scale <= 1)
            if scale > 1.001 {
                Button("Paskan foto", systemImage: "arrow.down.right.and.arrow.up.left") { viewports[side] = Viewport() }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .tint(.white)
        .background(.black.opacity(0.35), in: .rect(cornerRadius: 8))
        .padding(8)
    }

    @ViewBuilder
    private func drawPrompt(_ tree: TreeDocument) -> some View {
        if tree.run.type == .bunchWeight, tree.sides[side].annotations.isEmpty, !drawing, pendingLink == nil {
            Button("Gambar kotak tandan", systemImage: "plus") {
                mode = .edit
                drawing = true
                selected = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func photoFooter(_ tree: TreeDocument) -> some View {
        VStack(spacing: 6) {
            if pendingLink != nil {
                Text(tree.sides.count == 2 ? "Ketuk tandan yang sama pada foto ini"
                     : "Geser ke foto bersebelahan, lalu ketuk tandan yang sama")
                    .font(.callout.bold())
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.yellow.opacity(0.92), in: .rect(cornerRadius: 8))
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("link-hint")
            }
            if let toast {
                Text(toast)
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.85), in: .rect(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("link-replaced-toast")
            }
            if savedPulse {
                Label("Tersimpan", systemImage: "checkmark")
                    .font(.callout.bold())
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.green, in: .capsule)
                    .foregroundStyle(.white)
                    .transition(.opacity)
                    .accessibilityIdentifier("saved-pulse")
            }
        }
        .padding(.bottom, 12)
        .allowsHitTesting(false)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ tree: TreeDocument, panel: BoxRef?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if field == nil {
                HStack {
                    Picker("Mode", selection: Binding(get: { mode }, set: { mode = $0; drawing = false })) {
                        Text("Tinjau").tag(EditorMode.review)
                        Text("Edit").tag(EditorMode.edit)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Toggle("Tampilkan kotak", systemImage: showBoxes ? "eye" : "eye.slash", isOn: $showBoxes)
                        .toggleStyle(.button)
                        .labelStyle(.iconOnly)
                }
                boxMenu(tree)
                if mode == .edit {
                    Toggle("Gambar kotak", systemImage: "crop", isOn: $drawing)
                        .toggleStyle(.button)
                        .onChange(of: drawing) { _, value in if value { pendingLink = nil } }
                }
                if detecting { ProgressView("Mendeteksi tandan…") }
                if tree.run.type == .multiside {
                    ripenessBar(tree)
                }
            }
            if let panel, let box = tree.annotation(panel) {
                MeasurementFields(number: number(of: panel, in: tree), draft: $draft, focus: $field) {
                    field = nil
                    selected = nil
                }
                if field == nil { selectionActions(tree, selected: panel, box: box) }
            } else if let pendingLink {
                Button("Batalkan tautan", systemImage: "xmark", role: .destructive) {
                    self.pendingLink = nil
                }
                .accessibilityHint("Tautan dari foto \(pendingLink.side + 1)")
            } else if let selected, let box = tree.annotation(selected) {
                selectionActions(tree, selected: selected, box: box)
            }
            if field == nil {
                if let status {
                    Text(status).foregroundStyle(.secondary).accessibilityIdentifier("save-status")
                }
                if tree.run.type == .bunchWeight, panel == nil, let error = tree.completionError {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                }
                if tree.run.type == .multiside {
                    let mismatches = tree.classMismatches()
                    if !mismatches.isEmpty {
                        Button("Selesaikan perbedaan kelas (\(mismatches.count))", systemImage: "exclamationmark.triangle") {
                            showMismatch = true
                        }
                        .tint(.orange)
                        .accessibilityIdentifier("resolve-mismatch")
                    }
                }
                if tree.run.type == .multiside && tree.sides.count > 1 {
                    Button("Dedup", systemImage: "link.badge.plus") { showSuggestions = true }
                        .disabled(detecting)
                        .accessibilityIdentifier("open-dedup")
                    Toggle("Geser ke kanan untuk foto berikutnya", isOn: Binding(
                        get: { reverseSwipe ?? true }, set: { reverseSwipe = $0 }))
                }
                if panel == nil { exitActions(tree) }
            }
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func boxMenu(_ tree: TreeDocument) -> some View {
        let photo = tree.sides[side]
        let numbers = labels(tree, side: side)
        return Menu("Kotak anotasi", systemImage: "list.bullet.rectangle") {
            ForEach(photo.annotations) { box in
                let ref = BoxRef(side: photo.id, box: box.id)
                Button {
                    drawing = false
                    tap(box: box.id, side: photo.id)
                } label: {
                    let label = "Tandan \(numbers[box.id, default: 0])"
                    if selected == ref {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
            if mode == .edit && pendingLink == nil {
                if selected?.side == photo.id, let selected, let box = tree.annotation(selected) {
                    Button("Ubah koordinat kotak") {
                        boxCoordinates = BoxCoordinateTarget(photo: photo, ref: selected, rect: box.rect)
                    }
                    .disabled(detecting)
                }
                Button("Tambah kotak dengan koordinat") {
                    boxCoordinates = BoxCoordinateTarget(photo: photo)
                }
                .disabled(detecting)
            }
        }
        .disabled(photo.annotations.isEmpty && (mode == .review || pendingLink != nil))
        .accessibilityHint("Pilih tandan pada foto ini. Gunakan mode Edit untuk memasukkan koordinat kotak.")
    }

    private func ripenessBar(_ tree: TreeDocument) -> some View {
        let current = selected.flatMap { tree.annotation($0)?.ripeness }
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(Ripeness.allCases.filter { $0 != .unassigned }) { value in
                Button {
                    guard let selected else { return }
                    persist { tree in
                        let members = tree.clusters.first { $0.contains(selected) } ?? [selected]
                        for member in members { tree.setRipeness(member, ripeness: value) }
                    }
                } label: {
                    Text(value.label).font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(ripenessColor(value))
                .overlay {
                    if current == value { RoundedRectangle(cornerRadius: 8).stroke(.primary, lineWidth: 3) }
                }
                .disabled(selected == nil)
                .accessibilityAddTraits(current == value ? .isSelected : [])
            }
        }
    }

    private func selectionActions(_ tree: TreeDocument, selected: BoxRef, box: Annotation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if tree.run.type != .bunchWeight {
                Text("Tandan \(number(of: selected, in: tree))").font(.headline)
            }
            if tree.sides.count > 1 {
                Button("Tautkan ke foto lain", systemImage: "link") { armLink(from: selected, in: tree) }
                let suggestions = tree.suggestedLinks(from: selected, clockwise: clockwise)
                if !suggestions.isEmpty {
                    Menu("Saran tautan", systemImage: "link.badge.plus") {
                        ForEach(suggestions, id: \.self) { candidate in
                            Button("Foto \(candidate.side + 1) · Tandan \(number(of: candidate, in: tree))") {
                                connect(source: selected, target: candidate)
                            }
                        }
                    }
                }
            }
            ForEach(tree.links.filter { $0.a == selected || $0.b == selected }) { link in
                let other = link.a == selected ? link.b : link.a
                Button("Lepas tautan dari foto \(other.side + 1)", systemImage: "link.badge.plus") {
                    persistWithStatus { $0.unlink(link.id); return "Tautan dilepas." }
                }
            }
            Button("Hapus kotak", systemImage: "trash", role: .destructive) {
                field = nil
                persist { $0.deleteBox(selected); self.selected = nil }
            }
        }
    }

    @ViewBuilder
    private func exitActions(_ tree: TreeDocument) -> some View {
        Divider()
        if tree.run.type == .bunchWeight {
            Button("Simpan draf & keluar", systemImage: "tray.and.arrow.down", action: exit)
                .disabled(detecting)
            Button(onNext == nil ? "Selesaikan sampel" : "Simpan & sampel berikutnya", systemImage: "checkmark.circle") {
                finish(next: onNext != nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tree.completionError != nil || detecting)
        } else {
            Button("Simpan & keluar", systemImage: "checkmark.circle") { finish(next: false) }
                .buttonStyle(.borderedProminent)
                .disabled(detecting)
            if onNext != nil {
                Button("Pohon berikutnya", systemImage: "arrow.right.circle") { finish(next: true) }
                    .disabled(detecting)
            }
        }
    }

    // MARK: Actions

    private func addBox(_ rect: PixelBox, side: Int) {
        persist { tree in
            if let ref = tree.addBox(side: side, rect: rect) { selected = ref }
        }
    }

    private func show(side value: Int, animated: Bool) {
        guard let document, document.sides.indices.contains(value) else { return }
        side = value
        selected = nil
        drawing = false
        if pagerSide != value {
            if animated { withAnimation(.snappy) { pagerSide = value } } else { pagerSide = value }
        }
    }

    private func tap(box: String?, side tapped: Int) {
        guard tapped == side else { return }
        let ref = box.map { BoxRef(side: tapped, box: $0) }
        if let source = pendingLink, let ref {
            if ref.side != source.side {
                connect(source: source, target: ref)
                return
            }
            pendingLink = nil
        }
        selected = ref
    }

    private func armLink(from source: BoxRef, in tree: TreeDocument) {
        pendingLink = source
        drawing = false
        if tree.sides.count == 2 { show(side: 1 - source.side, animated: true) }
    }

    private func connect(source: BoxRef, target: BoxRef) {
        guard let document, document.canLink(source, target) else {
            status = "Pilih kotak pada foto yang bersebelahan dengan Foto \(source.side + 1)."
            return
        }
        pendingLink = nil
        if side != target.side { show(side: target.side, animated: true) }
        selected = target
        var replaced = false
        persistWithStatus { tree in
            replaced = tree.link(source, target)
            return "Tautan tersimpan."
        }
        if replaced { showToast("Tertaut. Ukuran dari foto lain menggantikan nilai pada tandan ini.") }
    }

    private func exit() {
        guard !saving, !detecting else { return }
        guard let document else {
            dismiss()
            return
        }
        field = nil
        if document.run.type == .bunchWeight {
            persist(then: { dismiss() }) { _ in }
        } else {
            finish(next: false)
        }
    }

    private func finish(next: Bool) {
        guard !detecting else { return }
        persist(markComplete: true, then: {
            dismiss()
            if next { onNext?() }
        }) { _ in }
    }

    private func applyMeasurements() {
        guard let selected, !saving else { return }
        switch draft.parsed() {
        case let .success(value):
            draft.error = nil
            field = nil
            persist { $0.setMeasurements(selected, value) }
        case let .failure(error):
            draft.error = error.message
        }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard toastToken == token else { return }
            withAnimation { toast = nil }
        }
    }

    private func zoom(by factor: CGFloat) {
        var viewport = viewports[side] ?? Viewport()
        let zoom = min(Viewport.maxZoom, max(1, viewport.zoom * factor))
        let ratio = zoom / viewport.zoom
        viewport.offset = CGSize(width: viewport.offset.width * ratio, height: viewport.offset.height * ratio)
        viewport.zoom = zoom
        viewports[side] = viewport
    }

    private func detect() {
        guard let tree = document, !saving, !detecting else { return }
        let target = side
        let info = tree.sides[target]
        detecting = true
        Task {
            defer { detecting = false }
            do {
                let url = await store.photoURL(treeID: id, side: target)
                let jpeg = try Data(contentsOf: url)
                let found = try await Detector.shared.detect(CapturedPhoto(jpeg: jpeg, width: info.width, height: info.height))
                guard var probe = document else { return }
                guard !probe.mergeDetections(side: target, found).isEmpty else {
                    status = "Deteksi tidak menemukan tandan baru pada Foto \(target + 1)."
                    return
                }
                persistWithStatus { tree in
                    let added = tree.mergeDetections(side: target, found).count
                    return "\(added) kotak baru dari deteksi pada Foto \(target + 1)."
                }
            } catch {
                self.error = error.localizedDescription + " Anotasi manual tetap dapat dilakukan."
            }
        }
    }

    private func persist(markComplete: Bool = false, then: (() -> Void)? = nil, _ edit: (inout TreeDocument) -> Void) {
        persistWithStatus(markComplete: markComplete, then: then) { tree in
            edit(&tree)
            return nil
        }
    }

    private func persistWithStatus(markComplete: Bool = false, then: (() -> Void)? = nil,
                                   _ edit: (inout TreeDocument) -> String?) {
        guard !saving, var updated = document else { return }
        let message = edit(&updated)
        document = updated
        saving = true
        Task {
            defer { saving = false }
            do {
                document = try await store.save(updated, markComplete: markComplete)
                status = message ?? (markComplete ? "Sampel selesai dan tersimpan." : "Perubahan tersimpan.")
                pulse()
                then?()
            } catch {
                self.error = error.localizedDescription
                if let stored = try? await store.tree(id: id) { document = stored }
            }
        }
    }

    private func pulse() {
        withAnimation { savedPulse = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            withAnimation { savedPulse = false }
        }
    }

    private func load() async {
        do {
            let tree = try await store.tree(id: id)
            document = tree
            if pagerSide == nil { pagerSide = side }
            await loadImage(side)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadImage(_ index: Int) async {
        guard document?.sides.indices.contains(index) ?? true, index >= 0 else { return }
        if cache.image(index) != nil {
            cache.touch(index)
            return
        }
        let url = await store.photoURL(treeID: id, side: index)
        if !(await cache.load(side: index, url: url)) { unreadable.insert(index) }
    }

    // MARK: Helpers

    private func labels(_ tree: TreeDocument, side: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: tree.clusters.enumerated().flatMap { index, cluster in
            cluster.filter { $0.side == side }.map { ($0.box, index + 1) }
        })
    }

    private func linkGroups(_ tree: TreeDocument, side: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: tree.linkGroups().filter { $0.key.side == side }.map { ($0.key.box, $0.value) })
    }

    private func number(of ref: BoxRef, in tree: TreeDocument) -> Int {
        tree.clusters.firstIndex { $0.contains(ref) }.map { $0 + 1 } ?? 0
    }
}

func ripenessColor(_ ripeness: Ripeness) -> Color {
    switch ripeness {
    case .unassigned: .white
    case .b1: .blue
    case .b2: .red
    case .b3: .orange
    case .b4: .purple
    }
}

private enum EditorMode: Hashable {
    case review, edit
}

struct Viewport: Equatable {
    static let maxZoom: CGFloat = 12
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
}

private struct ViewTransform {
    let size: CGSize
    let scale: CGFloat
    let origin: CGPoint
    let displayed: CGSize

    init(size: CGSize, width: Int, height: Int, viewport: Viewport) {
        self.size = size
        let fit = max(min(size.width / CGFloat(max(width, 1)), size.height / CGFloat(max(height, 1))), 0.0001)
        scale = fit * viewport.zoom
        displayed = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        func axis(_ view: CGFloat, _ content: CGFloat, _ offset: CGFloat) -> CGFloat {
            let centered = (view - content) / 2
            return content > view ? min(0, max(view - content, centered + offset)) : centered
        }
        origin = CGPoint(x: axis(size.width, displayed.width, viewport.offset.width),
                         y: axis(size.height, displayed.height, viewport.offset.height))
    }

    var offset: CGSize {
        CGSize(width: origin.x - (size.width - displayed.width) / 2, height: origin.y - (size.height - displayed.height) / 2)
    }

    func image(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    func screen(_ box: PixelBox) -> CGRect {
        CGRect(x: origin.x + CGFloat(box.x1) * scale, y: origin.y + CGFloat(box.y1) * scale,
               width: CGFloat(box.x2 - box.x1) * scale, height: CGFloat(box.y2 - box.y1) * scale)
    }
}

private struct AnnotationCanvas: View {
    let image: UIImage
    let side: CaptureSide
    let selected: String?
    let linkSource: String?
    let editing: Bool
    let drawing: Bool
    let showBoxes: Bool
    let labels: [String: Int]
    let linkGroups: [String: Int]
    let weighted: Bool
    @Binding var viewport: Viewport
    let onTap: (String?) -> Void
    let onGrab: (String) -> Void
    let onDraw: (PixelBox) -> Void
    let onChange: (String, PixelBox) -> Void
    @State private var drag: DragKind?
    @State private var preview: PixelBox?
    @State private var pinchBase: Viewport?

    private static let touchTolerance: CGFloat = 24
    private static let handleRadius: CGFloat = 22
    private static let minimumDraw: CGFloat = 24
    private static let minimumSide: Float = 5

    private enum Handle { case body, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }
    private enum DragKind {
        case draw
        case edit(id: String, handle: Handle, start: PixelBox)
        case pan(start: CGSize)
    }

    var body: some View {
        GeometryReader { proxy in
            let transform = ViewTransform(size: proxy.size, width: side.width, height: side.height, viewport: viewport)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: transform.displayed.width, height: transform.displayed.height)
                    .offset(x: transform.origin.x, y: transform.origin.y)
                Canvas { context, _ in render(context, transform) }
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(.rect)
            .gesture(SpatialTapGesture().onEnded { value in tap(value.location, transform) }, including: drawing ? .subviews : .all)
            .simultaneousGesture(magnify(transform))
            .gesture(dragGesture(transform), including: editing || viewport.zoom > 1.001 ? .all : .subviews)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Foto dengan kotak anotasi")
        .accessibilityValue("\(side.annotations.count) kotak, perbesaran \(String(format: "%.1f", viewport.zoom))x")
    }

    // MARK: Gestures

    private func tap(_ point: CGPoint, _ transform: ViewTransform) {
        let location = transform.image(point)
        onTap(pick(at: location, transform))
    }

    private func magnify(_ transform: ViewTransform) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil {
                    pinchBase = viewport
                    drag = nil
                    preview = nil
                }
                guard let base = pinchBase else { return }
                let zoom = min(Viewport.maxZoom, max(1, base.zoom * value.magnification))
                let before = ViewTransform(size: transform.size, width: side.width, height: side.height, viewport: base)
                let anchor = value.startLocation
                let pixel = before.image(anchor)
                let centered = ViewTransform(size: transform.size, width: side.width, height: side.height,
                                             viewport: Viewport(zoom: zoom))
                let origin = CGPoint(x: anchor.x - pixel.x * centered.scale, y: anchor.y - pixel.y * centered.scale)
                viewport = Viewport(zoom: zoom, offset: CGSize(width: origin.x - centered.origin.x,
                                                               height: origin.y - centered.origin.y))
            }
            .onEnded { _ in
                pinchBase = nil
                settle(transform.size)
            }
    }

    private func dragGesture(_ transform: ViewTransform) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard pinchBase == nil else { return }
                if drag == nil { drag = begin(at: value.startLocation, transform) }
                switch drag {
                case .draw:
                    let start = transform.image(value.startLocation)
                    let end = transform.image(value.location)
                    preview = clamped(PixelBox(x1: Float(min(start.x, end.x)), y1: Float(min(start.y, end.y)),
                                               x2: Float(max(start.x, end.x)), y2: Float(max(start.y, end.y))))
                case let .edit(_, handle, start):
                    preview = adjust(start, handle: handle, dx: Float(value.translation.width / transform.scale),
                                     dy: Float(value.translation.height / transform.scale))
                case let .pan(start):
                    viewport.offset = CGSize(width: start.width + value.translation.width,
                                             height: start.height + value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer {
                    drag = nil
                    preview = nil
                }
                switch drag {
                case .draw:
                    if abs(value.translation.width) >= Self.minimumDraw, abs(value.translation.height) >= Self.minimumDraw,
                       let preview { onDraw(preview) }
                case let .edit(id, _, start):
                    if let preview, preview != start { onChange(id, preview) }
                case .pan:
                    settle(transform.size)
                case nil:
                    break
                }
            }
    }

    private func begin(at point: CGPoint, _ transform: ViewTransform) -> DragKind {
        guard editing else { return .pan(start: viewport.offset) }
        if drawing { return .draw }
        if let selected, let box = side.annotations.first(where: { $0.id == selected }),
           let handle = handle(of: box.rect, at: point, transform) {
            return .edit(id: box.id, handle: handle, start: box.rect)
        }
        if let id = pick(at: transform.image(point), transform), let box = side.annotations.first(where: { $0.id == id }) {
            onGrab(box.id)
            return .edit(id: box.id, handle: .body, start: box.rect)
        }
        return .pan(start: viewport.offset)
    }

    private func handle(of box: PixelBox, at point: CGPoint, _ transform: ViewTransform) -> Handle? {
        let rect = transform.screen(box)
        let radius = min(Self.handleRadius, max(8, min(rect.width, rect.height) / 4))
        let nearLeft = abs(point.x - rect.minX) < radius
        let nearRight = abs(point.x - rect.maxX) < radius
        let nearTop = abs(point.y - rect.minY) < radius
        let nearBottom = abs(point.y - rect.maxY) < radius
        let withinX = point.x >= rect.minX && point.x <= rect.maxX
        let withinY = point.y >= rect.minY && point.y <= rect.maxY
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: break
        }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        return withinX && withinY ? .body : nil
    }

    private func adjust(_ box: PixelBox, handle: Handle, dx: Float, dy: Float) -> PixelBox {
        let width = Float(side.width)
        let height = Float(side.height)
        let minimum = Self.minimumSide
        func clamp(_ value: Float, _ low: Float, _ high: Float) -> Float { min(max(value, low), high) }
        var (x1, y1, x2, y2) = (box.x1, box.y1, box.x2, box.y2)
        switch handle {
        case .body:
            let dx = clamp(dx, -box.x1, width - box.x2)
            let dy = clamp(dy, -box.y1, height - box.y2)
            return PixelBox(x1: box.x1 + dx, y1: box.y1 + dy, x2: box.x2 + dx, y2: box.y2 + dy)
        case .topLeft, .left, .bottomLeft:
            x1 = clamp(box.x1 + dx, 0, box.x2 - minimum)
        case .topRight, .right, .bottomRight:
            x2 = clamp(box.x2 + dx, box.x1 + minimum, width)
        case .top, .bottom:
            break
        }
        switch handle {
        case .topLeft, .top, .topRight:
            y1 = clamp(box.y1 + dy, 0, box.y2 - minimum)
        case .bottomLeft, .bottom, .bottomRight:
            y2 = clamp(box.y2 + dy, box.y1 + minimum, height)
        default:
            break
        }
        return PixelBox(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    private func clamped(_ box: PixelBox) -> PixelBox {
        let width = Float(side.width)
        let height = Float(side.height)
        return PixelBox(x1: min(max(box.x1, 0), width), y1: min(max(box.y1, 0), height),
                        x2: min(max(box.x2, 0), width), y2: min(max(box.y2, 0), height))
    }

    private func settle(_ size: CGSize) {
        let shown = ViewTransform(size: size, width: side.width, height: side.height, viewport: viewport)
        viewport = viewport.zoom <= 1.001 ? Viewport() : Viewport(zoom: viewport.zoom, offset: shown.offset)
    }

    private func pick(at location: CGPoint, _ transform: ViewTransform) -> String? {
        BoxHitTest.pick(side.annotations, x: Float(location.x), y: Float(location.y),
                        tolerance: Float(Self.touchTolerance / transform.scale))
    }

    // MARK: Drawing

    private func render(_ context: GraphicsContext, _ transform: ViewTransform) {
        if showBoxes {
            for box in side.annotations {
                let active = box.id == selected
                var position = box.rect
                if case let .edit(id, _, _) = drag, id == box.id, let preview { position = preview }
                let rect = transform.screen(position)
                let color: Color = active ? .yellow : (weighted ? .green : ripenessColor(box.ripeness))
                let group = linkGroups[box.id]
                if let group {
                    context.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 4),
                                   with: .color(LinkPalette.color(group)),
                                   style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                }
                if box.id == linkSource {
                    context.stroke(Path(rect.insetBy(dx: -4, dy: -4)), with: .color(.yellow),
                                   style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
                context.stroke(Path(rect), with: .color(color), lineWidth: active ? 3 : 2)
                if let number = labels[box.id] {
                    let label = weighted || box.ripeness == .unassigned ? "\(number)" : "\(number) · \(box.ripeness.label)"
                    let text = context.resolve(Text(label).font(.caption.bold())
                        .foregroundStyle(group.map(LinkPalette.textColor) ?? .white))
                    let measured = text.measure(in: CGSize(width: 200, height: 40))
                    let badge = CGRect(x: rect.minX + 3, y: rect.minY + 3, width: measured.width + 6, height: measured.height + 2)
                    context.fill(Path(roundedRect: badge, cornerRadius: 3),
                                 with: .color(group.map(LinkPalette.color) ?? .black.opacity(0.6)))
                    context.draw(text, at: CGPoint(x: badge.minX + 3, y: badge.minY + 1), anchor: .topLeading)
                }
                if active && editing && !drawing {
                    for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                  CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                                  CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
                                  CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] {
                        let knob = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                        context.fill(Path(knob), with: .color(.yellow))
                        context.stroke(Path(knob), with: .color(.black), lineWidth: 1)
                    }
                }
            }
        }
        if case .draw = drag, let preview {
            context.stroke(Path(transform.screen(preview)), with: .color(.yellow), style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
        }
    }
}
