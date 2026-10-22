import SwiftUI
import AGRCore

/// Quick editor for one measure of a notation system: chord name, tab events (× / fret per string),
/// melody notes (degree / octave / accidental / duration) and lyrics per verse.
@MainActor
struct MeasureEditView: View {
    let title: String
    let defaultBeats: Double
    var onSave: (NotationMeasure) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NotationMeasure
    @State private var verseCount: Int

    init(title: String, measure: NotationMeasure, defaultBeats: Double, onSave: @escaping (NotationMeasure) -> Void) {
        self.title = title
        self.defaultBeats = defaultBeats
        self.onSave = onSave
        _draft = State(initialValue: measure)
        _verseCount = State(initialValue: measure.verseCount)
    }

    private var beats: Double { draft.beats ?? defaultBeats }

    var body: some View {
        NavigationStack {
            Form {
                chordSection
                tabSection
                melodySection
                lyricsSection
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }
                }
            }
        }
    }

    private func commit() {
        var result = draft
        result.tab.sort { $0.beat < $1.beat }
        result.melody.sort { $0.beat < $1.beat }
        result.chords.sort { $0.beat < $1.beat }
        MeasureEditing.addVerse(to: &result, verseCount: verseCount)
        MeasureEditing.trimEmptyVerses(&result)
        onSave(result)
        dismiss()
    }

    // MARK: Chords

    private var chordSection: some View {
        SwiftUI.Section {
            ForEach(Array(draft.chords.indices), id: \.self) { index in
                HStack {
                    TextField("和弦名", text: chordNameBinding(index))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Stepper(value: chordBeatBinding(index), in: 0...max(beats - 0.5, 0), step: 0.5) {
                        Text("第 \(beatText(draft.chords.indices.contains(index) ? draft.chords[index].beat : 0)) 拍")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { draft.chords.remove(atOffsets: $0) }
            Button {
                draft.chords.append(ChordMark(name: "C", beat: 0))
            } label: {
                Label("添加和弦", systemImage: "plus.circle")
            }
        } header: {
            Text("和弦")
        } footer: {
            Text("修改和弦名后，识别到的和弦图会被丢弃并按新和弦自动生成。")
        }
    }

    private func chordNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { draft.chords.indices.contains(index) ? draft.chords[index].name : "" },
            set: { value in
                guard draft.chords.indices.contains(index) else { return }
                if draft.chords[index].name != value { draft.chords[index].shape = nil }
                draft.chords[index].name = value
            }
        )
    }

    private func chordBeatBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { draft.chords.indices.contains(index) ? draft.chords[index].beat : 0 },
            set: { if draft.chords.indices.contains(index) { draft.chords[index].beat = $0 } }
        )
    }

    // MARK: Tab

    private static let durations: [Double] = [4, 3, 2, 1.5, 1, 0.75, 0.5, 0.375, 0.25, 0.125]

    private func durationOptions(including current: Double) -> [Double] {
        var list = Self.durations
        if !list.contains(where: { abs($0 - current) < 1e-6 }) { list.append(current); list.sort(by: >) }
        return list
    }

    private func durationLabel(_ value: Double) -> String {
        switch value {
        case 4: return "全音符"
        case 3: return "附点二分"
        case 2: return "二分"
        case 1.5: return "附点四分"
        case 1: return "四分"
        case 0.75: return "附点八分"
        case 0.5: return "八分"
        case 0.375: return "附点十六分"
        case 0.25: return "十六分"
        case 0.125: return "三十二分"
        default: return "\(beatText(value)) 拍"
        }
    }

    private func beatText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    private var tabSection: some View {
        SwiftUI.Section {
            ForEach(Array(draft.tab.indices), id: \.self) { index in
                tabEventEditor(index)
            }
            .onDelete { draft.tab.remove(atOffsets: $0) }
            Button {
                MeasureEditing.appendTabEvent(to: &draft, defaultBeats: defaultBeats)
            } label: {
                Label("添加六线谱事件", systemImage: "plus.circle")
            }
        } header: {
            Text("六线谱")
        } footer: {
            Text("每根弦可选“×”（按当前和弦指法拨弦）或品位数字；扫弦方向只画箭头。")
        }
    }

    @ViewBuilder
    private func tabEventEditor(_ index: Int) -> some View {
        if draft.tab.indices.contains(index) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper(value: tabBinding(index, \.beat), in: 0...max(beats - 0.125, 0), step: 0.25) {
                        Text("第 \(beatText(draft.tab[index].beat)) 拍").font(.subheadline)
                    }
                }
                HStack {
                    Picker("时值", selection: tabBinding(index, \.duration)) {
                        ForEach(durationOptions(including: draft.tab[index].duration), id: \.self) {
                            Text(durationLabel($0)).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    Spacer()
                    Picker("扫弦", selection: strokeBinding(index)) {
                        Text("无").tag(Int(0))
                        Text("↓").tag(Int(1))
                        Text("↑").tag(Int(2))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                HStack(spacing: 6) {
                    ForEach(1...6, id: \.self) { string in
                        stringCell(index, string: string)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func stringCell(_ index: Int, string: Int) -> some View {
        let current = draft.tab.indices.contains(index) ? MeasureEditing.cell(in: draft.tab[index], string: string) : .none
        let text: String
        switch current {
        case .none: text = "—"
        case .chordTone: text = "×"
        case .fret(let fret): text = "\(fret)"
        }
        var maxFret = 15
        if case .fret(let fret) = current { maxFret = max(maxFret, fret) }
        return Menu {
            Picker("第 \(string) 弦", selection: cellBinding(index, string: string)) {
                Text("无").tag(TabCell.none)
                Text("× 和弦音").tag(TabCell.chordTone)
                ForEach(0...maxFret, id: \.self) { fret in
                    Text("\(fret) 品").tag(TabCell.fret(fret))
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(text)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(current == .none ? Color.secondary.opacity(0.1) : Color.accentColor.opacity(0.18))
                    )
                Text("\(string)弦").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func tabBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<TabEvent, T>) -> Binding<T> {
        Binding(
            get: { draft.tab[min(index, draft.tab.count - 1)][keyPath: keyPath] },
            set: { value in
                if draft.tab.indices.contains(index) { draft.tab[index][keyPath: keyPath] = value }
            }
        )
    }

    private func strokeBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: {
                guard draft.tab.indices.contains(index) else { return 0 }
                switch draft.tab[index].stroke {
                case .down?: return 1
                case .up?: return 2
                case nil: return 0
                }
            },
            set: { value in
                guard draft.tab.indices.contains(index) else { return }
                draft.tab[index].stroke = value == 1 ? .down : (value == 2 ? .up : nil)
            }
        )
    }

    private func cellBinding(_ index: Int, string: Int) -> Binding<TabCell> {
        Binding(
            get: {
                guard draft.tab.indices.contains(index) else { return .none }
                return MeasureEditing.cell(in: draft.tab[index], string: string)
            },
            set: { value in
                guard draft.tab.indices.contains(index) else { return }
                MeasureEditing.setCell(value, in: &draft.tab[index], string: string)
            }
        )
    }

    // MARK: Melody

    private var melodySection: some View {
        SwiftUI.Section {
            ForEach(Array(draft.melody.indices), id: \.self) { index in
                melodyEditor(index)
            }
            .onDelete { draft.melody.remove(atOffsets: $0) }
            Button {
                MeasureEditing.appendMelodyNote(to: &draft, defaultBeats: defaultBeats)
            } label: {
                Label("添加音符", systemImage: "plus.circle")
            }
        } header: {
            Text("简谱旋律")
        } footer: {
            Text("0 表示休止；八度点 + 为高八度，− 为低八度。")
        }
    }

    @ViewBuilder
    private func melodyEditor(_ index: Int) -> some View {
        if draft.melody.indices.contains(index) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("音", selection: melodyBinding(index, \.degree)) {
                        ForEach(0...7, id: \.self) { Text($0 == 0 ? "0 休止" : "\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("变音", selection: melodyBinding(index, \.accidental)) {
                        Text("♭").tag(-1)
                        Text("♮").tag(0)
                        Text("♯").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    Spacer()
                    Toggle("连线", isOn: melodyBinding(index, \.tieToNext))
                        .toggleStyle(.button)
                        .font(.footnote)
                }
                HStack {
                    Stepper(value: melodyBinding(index, \.octave), in: -2...2) {
                        Text("八度 \(draft.melody[index].octave > 0 ? "+" : "")\(draft.melody[index].octave)")
                            .font(.footnote)
                    }
                }
                HStack {
                    Stepper(value: melodyBinding(index, \.beat), in: 0...max(beats - 0.125, 0), step: 0.25) {
                        Text("第 \(beatText(draft.melody[index].beat)) 拍").font(.footnote)
                    }
                }
                Picker("时值", selection: melodyBinding(index, \.duration)) {
                    ForEach(durationOptions(including: draft.melody[index].duration), id: \.self) {
                        Text(durationLabel($0)).tag($0)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.vertical, 4)
        }
    }

    private func melodyBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<MelodyNote, T>) -> Binding<T> {
        Binding(
            get: { draft.melody[min(index, draft.melody.count - 1)][keyPath: keyPath] },
            set: { value in
                if draft.melody.indices.contains(index) { draft.melody[index][keyPath: keyPath] = value }
            }
        )
    }

    // MARK: Lyrics

    @ViewBuilder
    private var lyricsSection: some View {
        ForEach(0..<max(verseCount, 0), id: \.self) { verse in
            SwiftUI.Section("第 \(verse + 1) 段歌词") {
                ForEach(Array(draft.melody.indices), id: \.self) { index in
                    if draft.melody.indices.contains(index) {
                        HStack {
                            Text("\(draft.melody[index].degree)")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            Text(beatText(draft.melody[index].beat))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            TextField("歌词", text: lyricBinding(index, verse: verse))
                        }
                    }
                }
            }
        }
        SwiftUI.Section {
            Button {
                verseCount += 1
            } label: {
                Label("添加一段歌词", systemImage: "plus.circle")
            }
            .disabled(draft.melody.isEmpty)
        }
    }

    private func lyricBinding(_ index: Int, verse: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.melody.indices.contains(index), verse < draft.melody[index].lyrics.count else { return "" }
                return draft.melody[index].lyrics[verse]
            },
            set: { value in
                guard draft.melody.indices.contains(index) else { return }
                MeasureEditing.setLyric(value, note: &draft.melody[index], verse: verse)
            }
        )
    }
}

extension View {
    /// Presents `MeasureEditView` for the tapped measure and writes the result back into `score`.
    func measureEditSheet(score: Binding<Score>, editing: Binding<NotationMeasureRef?>) -> some View {
        sheet(item: editing) { ref in
            if let measure = score.wrappedValue.notationMeasure(ref) {
                MeasureEditView(
                    title: "第 \(ref.measure + 1) 小节",
                    measure: measure,
                    defaultBeats: Double(max(score.wrappedValue.meta.timeSignature.beats, 1))
                ) { updated in
                    var copy = score.wrappedValue
                    copy.updateNotationMeasure(ref, updated)
                    score.wrappedValue = copy
                }
            }
        }
    }
}
