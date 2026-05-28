import UnifiedQuery
import SwiftUI

/// Minimal record that stands in for the app's "source-of-truth DB".
/// In a real app this would be a SwiftData / Core Data entity.
struct Record: Identifiable, Hashable {
    let id: Int64
    let text: String
}

/// UI-facing list of search algorithms, mapped to the FFI enum.
enum StrategyOption: String, CaseIterable, Identifiable {
    case trigramBm25
    case substring
    case prefix
    case suffix
    case allTerms
    case fuzzyTrigram
    case levenshtein
    case damerauLevenshtein

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trigramBm25: return "trigram + bm25"
        case .substring: return "substring"
        case .prefix: return "prefix"
        case .suffix: return "suffix"
        case .allTerms: return "all terms"
        case .fuzzyTrigram: return "fuzzy trigram"
        case .levenshtein: return "levenshtein"
        case .damerauLevenshtein: return "damerau-levenshtein"
        }
    }

    var ffi: SearchStrategy {
        switch self {
        case .trigramBm25: return .trigramBm25
        case .substring: return .substring
        case .prefix: return .prefix
        case .suffix: return .suffix
        case .allTerms: return .allTerms
        case .fuzzyTrigram: return .fuzzyTrigram
        case .levenshtein: return .levenshtein
        case .damerauLevenshtein: return .damerauLevenshtein
        }
    }
}

/// One normalization step toggle, bound to a field of `NormalizeOptions`.
struct OptionToggle: Identifiable {
    let id: String
    let label: String
    let keyPath: WritableKeyPath<NormalizeOptions, Bool>
}

let optionToggles: [OptionToggle] = [
    OptionToggle(id: "lowercase", label: "小文字化", keyPath: \.lowercase),
    OptionToggle(id: "kana_fold", label: "カナ→かな", keyPath: \.kanaFold),
    OptionToggle(id: "fold_diacritics", label: "アクセント除去 (café→cafe)", keyPath: \.foldDiacritics),
    OptionToggle(id: "fold_choonpu", label: "長音畳み込み (サーバー→サーバ)", keyPath: \.foldChoonpu),
    OptionToggle(id: "expand_iteration_marks", label: "繰り返し記号展開 (時々→時時)", keyPath: \.expandIterationMarks),
    OptionToggle(id: "normalize_hyphens", label: "ハイフン統一", keyPath: \.normalizeHyphens),
    OptionToggle(id: "strip_digit_grouping", label: "桁区切り除去 (1,000→1000)", keyPath: \.stripDigitGrouping),
    OptionToggle(id: "collapse_whitespace", label: "空白圧縮", keyPath: \.collapseWhitespace),
]

/// The `loose` preset as composable options (lowercase + kana fold).
private func looseOptions() -> NormalizeOptions {
    NormalizeOptions(
        lowercase: true,
        kanaFold: true,
        foldDiacritics: false,
        foldChoonpu: false,
        expandIterationMarks: false,
        normalizeHyphens: false,
        stripDigitGrouping: false,
        collapseWhitespace: false
    )
}

@MainActor
final class SearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var status: String = ""
    @Published var results: [Record] = []

    /// Toggling any normalization step or strategy rebuilds the engine.
    @Published var options: NormalizeOptions = looseOptions() {
        didSet { if options != oldValue { reconfigure() } }
    }
    @Published var strategy: StrategyOption = .trigramBm25 {
        didSet { if strategy != oldValue { reconfigure() } }
    }

    private var engine: SearchEngine
    private let dbPath: String
    /// The engine returns only IDs and scores, so the host side maps id → Record.
    private var store: [Int64: Record] = [:]

    init() {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("search_index.sqlite")
        self.dbPath = url.path
        do {
            self.engine = try SearchModel.makeEngine(
                options: looseOptions(), strategy: .trigramBm25, dbPath: url.path
            )
        } catch {
            fatalError("open SearchEngine failed: \(error)")
        }
        seedIfNeeded()
    }

    /// Opens the index for the given composable options. Changing the enabled
    /// steps regenerates the index in place from the retained raw text
    /// (`withOptionsRebuilding`), so the host never re-feeds documents.
    private static func makeEngine(
        options: NormalizeOptions, strategy: SearchStrategy, dbPath: String
    ) throws -> SearchEngine {
        try SearchEngine.withOptionsRebuilding(
            dbPath: dbPath,
            config: EngineOptionsConfig(normalize: options, strategy: strategy)
        )
    }

    /// Rebuilds the engine for the current options/strategy and refreshes results.
    private func reconfigure() {
        do {
            engine = try SearchModel.makeEngine(
                options: options, strategy: strategy.ffi, dbPath: dbPath
            )
            status = "rebuilt under current settings"
            if !query.isEmpty { search() }
        } catch {
            status = "reconfigure error: \(error)"
        }
    }

    private func seedIfNeeded() {
        let seed: [Record] = [
            Record(id: 1, text: "東京タワー"),
            Record(id: 2, text: "とうきょうスカイツリー"),
            Record(id: 3, text: "ﾄｳｷｮｳ ﾄﾞｰﾑ"),
            Record(id: 4, text: "Osaka 城"),
            Record(id: 5, text: "がっこう ぐらし"),
            Record(id: 6, text: "かっこう の歌"),
            Record(id: 7, text: "Ｐｙｔｈｏｎ 入門"),
            Record(id: 8, text: "ぱんだ と ﾊﾟﾝﾀﾞ"),
            Record(id: 9, text: "コーヒーサーバー"),
            Record(id: 10, text: "café オレ")
        ]
        for record in seed {
            try? engine.index(id: record.id, text: record.text)
            store[record.id] = record
        }
        status = "indexed \(seed.count) docs"
        // UI-test hooks: preselect steps and/or run a query on launch. Setting
        // `options`/`strategy` after init triggers the same reconfigure path as
        // toggling the controls. SEARCH_OPTIONS is a comma-separated step id list.
        let env = ProcessInfo.processInfo.environment
        if env["SEARCH_AUTO_QUERY"] != nil || env["SEARCH_OPTIONS"] != nil || env["SEARCH_STRATEGY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if let raw = env["SEARCH_OPTIONS"] {
                    self.options = SearchModel.parseOptions(raw)
                }
                if let s = env["SEARCH_STRATEGY"].flatMap(StrategyOption.init(rawValue:)) {
                    self.strategy = s
                }
                if let auto = env["SEARCH_AUTO_QUERY"] {
                    self.query = auto
                }
                self.search()
            }
        }
    }

    /// Builds options from a comma-separated list of step ids (see `optionToggles`).
    static func parseOptions(_ raw: String) -> NormalizeOptions {
        let enabled = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var options = NormalizeOptions(
            lowercase: false, kanaFold: false, foldDiacritics: false, foldChoonpu: false,
            expandIterationMarks: false, normalizeHyphens: false,
            stripDigitGrouping: false, collapseWhitespace: false
        )
        for toggle in optionToggles where enabled.contains(toggle.id) {
            options[keyPath: toggle.keyPath] = true
        }
        return options
    }

    func search() {
        do {
            let hits = try engine.search(query: query, limit: 50)
            results = hits.compactMap { store[$0.id] }
            let normalized = normalizeWithOptions(input: query, options: options)
            status = "hits: \(results.count)  normalized=\u{0022}\(normalized)\u{0022}"
        } catch {
            status = "error: \(error)"
            results = []
        }
    }

    /// Explicitly regenerates the index from the retained raw text under the
    /// current settings (distinct from the automatic rebuild on a settings
    /// change). Useful after the normalization rules themselves change.
    func reindex() {
        do {
            let count = try engine.reindex()
            status = "reindexed \(count) docs"
            if !query.isEmpty { search() }
        } catch {
            status = "reindex error: \(error)"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SearchModel()

    private func binding(_ keyPath: WritableKeyPath<NormalizeOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.options[keyPath: keyPath] },
            set: { model.options[keyPath: keyPath] = $0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("正規化ステップ") {
                    ForEach(optionToggles) { toggle in
                        Toggle(toggle.label, isOn: binding(toggle.keyPath))
                            .font(.callout)
                    }
                }
                Section("検索") {
                    Picker("アルゴリズム", selection: $model.strategy) {
                        ForEach(StrategyOption.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("検索クエリ(全角/半角/カナ/ひら、なんでも)", text: $model.query)
                        .onSubmit { model.search() }
                    HStack {
                        Button("検索") { model.search() }
                        Spacer()
                        Button("インデックス再生成") { model.reindex() }
                            .tint(.secondary)
                    }
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("結果") {
                    ForEach(model.results) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.text).font(.body)
                            Text("id=\(record.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("SearchSample")
        }
    }
}
