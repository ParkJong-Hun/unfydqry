# クロスプラットフォーム検索エンジン 設計方針

iOS(SwiftData)と Android(Room)の両方から使える、共通の全文検索エンジンを
**Rust + UniFFI** で実装するための設計方針まとめ。

検索の曖昧軸は **大文字小文字・全角半角・かな種別(カタカナ/ひらがな)** を畳み込み、
**濁点・半濁点は区別する**(`か` と `が` は別物)。

---

## 1. 全体アーキテクチャ

### 1.1 基本構成 — インデックス所有型

検索エンジンは **自前の SQLite + FTS5 インデックスファイルを所有**する。
アプリ本体のデータ(SwiftData / Room)はあくまで「正(source of truth)」で、
エンジンは「検索インデックス」として独立して存在する。

```
┌─────────────────────────────┐     ┌──────────────────────────────┐
│  iOS アプリ                  │     │  Android アプリ               │
│  ┌────────────────────────┐ │     │ ┌──────────────────────────┐ │
│  │ SwiftData (本体DB=正)   │ │     │ │ Room (本体DB=正)          │ │
│  └───────────┬────────────┘ │     │ └────────────┬─────────────┘ │
│              │ index/remove  │     │              │ index/remove  │
│  ┌───────────▼────────────┐ │     │ ┌────────────▼─────────────┐ │
│  │ SearchEngine (Swift binding) │ │ │ SearchEngine (Kotlin binding)│
│  └───────────┬────────────┘ │     │ └────────────┬─────────────┘ │
└──────────────┼──────────────┘     └──────────────┼───────────────┘
               │                                    │
        ┌──────▼────────────────────────────────────▼──────┐
        │      Rust コア (UniFFI)  ※実装は物理的に1つ        │
        │   正規化 / FTS5管理 / ランキング / トークナイズ     │
        │   └─ rusqlite(bundled SQLite + FTS5 trigram)      │
        └───────────────────────────────────────────────────┘
        search_index.sqlite (本体DBとは別ファイル)
```

### 1.2 設計上の重要決定

| 決定事項 | 内容 | 理由 |
|---|---|---|
| 実装の単一化 | 検索ロジックを Rust に1実装だけ置き、Swift/Kotlin へ UniFFI で自動バインディング | アルゴリズム一致を「努力目標」ではなく**構造的に保証**する |
| インデックス独立 | `search_index.sqlite` を本体DBと別ファイルにする | SwiftData/Room の整合性チェック(スキーマ検証・CloudKit連携)を壊さない |
| ID のみ返却 | 検索結果は安定キー(IDのみ)を返し、本体は各OSで再フェッチ | エンジンが本体DB実装に結合しない・移植性を保つ |
| 曖昧さは正規化で実現 | 近似マッチ(編集距離)ではなく、正規化で軸を畳み込む | 単純な部分一致がそのまま曖昧検索になり、高速かつ決定的 |
| SQLite を同梱 | rusqlite の `bundled` で FTS5/trigram 付き SQLite をコンパイル | OS同梱 SQLite のバージョン差を踏まない(trigram は 3.34+) |

### 1.3 データフロー

- **書き込み**: 本体DBへ保存 → 生テキストを `index(id, text)` でエンジンに渡す(正規化はエンジン内部で実行)
- **検索**: `search(query, limit)` に生入力を渡す → エンジンが同じ正規化を通して FTS5 を引く → `(id, score)` を返す → 本体DBからIDで再フェッチ
- **削除**: 本体から削除 → `remove(id)`

---

## 2. 正規化の方針(検索エンジンの心臓部)

### 2.1 畳み込む軸と担当ステップ

| 曖昧にする軸 | 担当 | 仕組み |
|---|---|---|
| 全角 / 半角 | NFKC(互換合成) | Ａ→A、ｶ→カ を正準形へ畳む。**濁点は合成形のまま保持** |
| 大文字 / 小文字 | `char::to_lowercase` | Latin を小文字化 |
| かな種別(カナ/かな) | カタカナ→ひらがな写像 | カ↔か を統一 |
| 濁点 / 半濁点 | **畳み込まない(区別する)** | `か` と `が` は別キー |

> **NFKC を選ぶ理由**: 濁点を区別するため、結合文字へ分解する NFKD は使わない。
> NFKD だと `が` が `か`+U+3099 に分かれてキーが不安定になる。NFKC なら
> 全半角を畳みつつ濁点は単一の合成文字として安定する。

### 2.2 正規化コア(確定版)

```rust
use unicode_normalization::UnicodeNormalization;

fn katakana_to_hiragana(c: char) -> char {
    match c as u32 {
        // 濁点付き(ガ=U+30AC, ヴ=U+30F4 等)も -0x60 で正しく写る
        0x30A1..=0x30F6 => char::from_u32(c as u32 - 0x60).unwrap_or(c),
        _ => c,
    }
}

/// 大小・全半角・かな種別を畳み込む。濁点/半濁点は保持する。
pub fn normalize_loose(input: &str) -> String {
    input
        .nfkc()                          // ① 全半角統一(濁点は合成形のまま)
        .map(katakana_to_hiragana)       // ② カタカナ→ひらがな
        .flat_map(char::to_lowercase)    // ③ 大文字→小文字
        .collect()
}

#[uniffi::export(name = "normalizeLoose")]
pub fn normalize_loose_ffi(input: String) -> String {
    normalize_loose(&input)
}
```

動作トレース:

```
ガ / が / ｶﾞ      → が     (全半角・かな種別は畳むが、濁点は区別)
カ / か / ｶ       → か     (濁点ありとは別キー)
パ / ぱ / ﾊﾟ      → ぱ
Ｐ / P / ｐ / p   → p
ヴ / ｳﾞ           → ゔ
```

---

## 3. 検索エンジン本体(確定版)

`rusqlite`(bundled)+ FTS5 trigram。3文字未満は LIKE にフォールバック。

```rust
use std::sync::{Arc, Mutex};
use rusqlite::{Connection, params};

uniffi::setup_scaffolding!();

#[derive(uniffi::Record)]
pub struct Hit { pub id: i64, pub score: f64 }

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SearchError {
    #[error("{0}")]
    Db(String),
}
impl From<rusqlite::Error> for SearchError {
    fn from(e: rusqlite::Error) -> Self { SearchError::Db(e.to_string()) }
}

#[derive(uniffi::Object)]
pub struct SearchEngine { conn: Mutex<Connection> }

#[uniffi::export]
impl SearchEngine {
    #[uniffi::constructor]
    pub fn new(db_path: String) -> Result<Arc<Self>, SearchError> {
        let conn = Connection::open(db_path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;   // 読み取り並行性
        conn.execute_batch(
            "CREATE VIRTUAL TABLE IF NOT EXISTS docs
                 USING fts5(norm, tokenize='trigram');
             CREATE TABLE IF NOT EXISTS entries(
                 id INTEGER PRIMARY KEY, norm TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS meta(
                 key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        Ok(Arc::new(Self { conn: Mutex::new(conn) }))
    }

    /// ホストは正規化前の生テキストを渡すだけ。正規化はエンジン内で実行。
    pub fn index(&self, id: i64, text: String) -> Result<(), SearchError> {
        let norm = normalize_loose(&text);
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM docs WHERE rowid=?1", params![id])?;
        conn.execute("INSERT INTO docs(rowid, norm) VALUES (?1, ?2)", params![id, &norm])?;
        conn.execute("INSERT OR REPLACE INTO entries(id, norm) VALUES (?1, ?2)", params![id, &norm])?;
        Ok(())
    }

    pub fn remove(&self, id: i64) -> Result<(), SearchError> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM docs WHERE rowid=?1", params![id])?;
        conn.execute("DELETE FROM entries WHERE id=?1", params![id])?;
        Ok(())
    }

    pub fn search(&self, query: String, limit: u32) -> Result<Vec<Hit>, SearchError> {
        let q = normalize_loose(&query);
        let conn = self.conn.lock().unwrap();

        // trigram は3文字未満をマッチできない → LIKE フォールバック
        if q.chars().count() < 3 {
            let mut stmt = conn.prepare(
                "SELECT id FROM entries WHERE norm LIKE '%'||?1||'%' LIMIT ?2")?;
            let rows = stmt.query_map(params![q, limit],
                |r| Ok(Hit { id: r.get(0)?, score: 0.0 }))?;
            return Ok(rows.filter_map(Result::ok).collect());
        }

        // FTS5 構文の誤解釈を防ぐためフレーズとして渡す
        let phrase = format!("\"{}\"", q.replace('"', "\"\""));
        let mut stmt = conn.prepare(
            "SELECT rowid, bm25(docs) FROM docs
                 WHERE docs MATCH ?1 ORDER BY bm25(docs) LIMIT ?2")?;
        let rows = stmt.query_map(params![phrase, limit],
            |r| Ok(Hit { id: r.get(0)?, score: r.get(1)? }))?;
        Ok(rows.filter_map(Result::ok).collect())
    }
}
```

### Cargo.toml

```toml
[lib]
crate-type = ["cdylib", "staticlib"]   # Android=cdylib, iOS=staticlib

[dependencies]
uniffi = { version = "0.28", features = ["cli"] }
rusqlite = { version = "0.32", features = ["bundled"] }  # FTS5/trigram 付き SQLite を同梱
unicode-normalization = "0.1"
thiserror = "1"

[build-dependencies]
uniffi = { version = "0.28", features = ["build"] }
```

バインディング生成:
```
uniffi-bindgen generate --library <built lib> --language swift
uniffi-bindgen generate --library <built lib> --language kotlin
```

### ホスト側の使用イメージ

```swift
// iOS
let engine = try SearchEngine(dbPath: url.path)
try engine.index(id: note.searchID, text: "\(note.title) \(note.body)")
let hits = try engine.search(query: "とうきよう", limit: 50)  // クエリ正規化もエンジン内
```
```kotlin
// Android — メソッド名は完全に同一
val engine = SearchEngine(dbPath)
engine.index(note.searchId, "${note.title} ${note.body}")
val hits = engine.search("トウキョウ", 50u)
```

---

## 4. 運用上の勘所

- **1〜2文字検索**: trigram は3文字未満を返さない。日本語は短いクエリが多いので
  LIKE フォールバックは必須(上のコードに実装済み)。
- **正規化はホストで再実装しない**: 表示・別用途でシャドウ列を持つ場合も、その値は
  必ず `normalizeLoose` から生成する。Swift/Kotlin で書き直すと一致保証の意味が消える。
- **スレッド安全性**: `Mutex<Connection>` は単純・確実だが直列化される。並行性が必要なら
  `r2d2_sqlite` でコネクションプール + WAL に。UniFFI Object は `Send + Sync` 必須。
- **バージョニングと再構築**: `meta` テーブルに `index_version` を持たせ、`normalize_loose`
  を変更したら全件 `rebuild` を走らせる。`entries` に正規化前の元データではなく正規化済み
  テキストを保管しているので、再構築は FTS へ流し直すだけで済む(※元テキスト保管に変える設計も可)。
- **同期(本体DB → インデックス)**:
  - iOS: SwiftData の**永続的履歴トラッキング**(iOS 18)で差分(挿入/更新/削除)を引いて反映
  - Android: Room の **InvalidationTracker** か SQLite トリガで変更を捕捉
  - オフライン編集が絡むなら本体に `searchIndexDirty` フラグを立てて遅延同期

---

## 5. 今後の拡張ポイント(未実装)

- **tight / loose 二段ランキング**: かな種別だけ畳んだ loose でヒットさせ、より厳密な
  正規形(かな種別も保持)に一致するものを上位にする。再現率と適合率の両立。
- **読み(よみがな)検索**: 漢字を読みで引きたい場合。辞書依存になるため、Rust コアに
  **Lindera(形態素解析器)+ 固定辞書**を同梱すれば両OS一致のまま実現可能。
  (OS内蔵の読み付与 = CFStringTokenizer / Android ICU は辞書が異なり一致しないため使わない)
- **セマンティック検索**: 埋め込みベクトル + 近似最近傍。同じ Rust コアに載せれば一貫管理できる。
- **ビルドパイプライン**: iOS 向け XCFramework、Android 向け AAR(`.so` 同梱)の自動化。

---

# 関連知識の解説

検索エンジン設計の背景にある技術を、判断の根拠とともに解説する。

## A. Unicode 正規化(NFC / NFD / NFKC / NFKD)

同じ「見た目の文字」が複数のコードポイント列で表現できるため、比較・検索の前に
正規化して表現を一意化する必要がある。正規化形は2軸の組み合わせで4種類ある。

| | 合成(Composed) | 分解(Decomposed) |
|---|---|---|
| **正準等価**(見た目・意味が同一) | NFC | NFD |
| **互換等価**(意味は同じだが体裁が違う) | NFKC | NFKD |

- **正準(Canonical)**: `が`(単一文字 U+304C)と `か`+濁点(U+304B U+3099)のような、
  本質的に同じ文字の表現ゆれを統一する。
- **互換(Compatibility, K)**: 全角 `Ａ` と半角 `A`、半角カナ `ｶ` と全角 `カ`、丸数字 `①` と
  `1` のような「意味は対応するが体裁が異なる」文字を統一する。**全半角の畳み込みはこの K が担う。**
- **合成 vs 分解**: 合成は結合済みの単一文字へ寄せ、分解は基底文字 + 結合文字へ分ける。

### なぜ本設計は NFKC か

- 全半角を畳みたい → **K(互換)が必須**。NFC/NFD では半角カナが畳まれない。
- 濁点は**区別**したい → **合成(C)** を選ぶ。NFKD(分解)だと `が`→`か`+U+3099 と
  結合文字に割れ、濁点を保持したいのにキーが不安定化する。NFKC なら `が` は単一の
  合成文字のまま安定する。

> 補足: 以前「濁点も曖昧にする」場合は NFKD で分解してから結合文字 U+3099(濁点)/
> U+309A(半濁点)を除去する手法だった。今回は濁点を区別するので、その除去ステップごと不要。

## B. 結合文字と濁点

- **U+3099**: 結合濁点(combining)。**U+309B**(` ゛`)は単独表示用で別物。
- **U+309A**: 結合半濁点。**U+309C**(` ゜`)は単独用。
- 半角濁点 **U+FF9E** / 半角半濁点 **U+FF9F** は、NFKC で前の半角カナと合成され、
  全角の合成済み濁点付きカナ(例: `ｶ`+`ﾞ` → `が`)になる。これにより半角入力の
  濁点も正しく1文字に揃う。

## C. SQLite FTS5 と trigram トークナイザ

- **FTS5**: SQLite の全文検索拡張。仮想テーブル `USING fts5(...)` で作り、`MATCH` 演算子で
  検索、`bm25()` でスコアリング、`snippet()` で抜粋が取れる。
- **トークナイザの選択が日本語の鍵**:
  - `unicode61`(既定): 空白区切り前提。**日本語はほぼ機能しない**(分かち書きしないため)。
  - **`trigram`**: 文字を3文字単位に機械分割する。空白のない CJK でも部分一致が成立するため
    日本語向き。辞書を一切引かないので**プラットフォーム非依存**(= 両OS一致に最適)。
  - 形態素解析(MeCab/Lindera): 単語境界で正確に分割。精度は最高だが辞書同梱が必要で重い。
- **trigram の制約**: 3文字未満のクエリはマッチ不可。→ 本設計では LIKE フォールバックで補う。
- **bm25()**: 単語頻度と文書長を加味した定番ランキング指標。値が小さいほど良適合(昇順ソート)。

## D. UniFFI(言語間バインディング自動生成)

Mozilla 製。Rust で書いたロジックを Swift / Kotlin から呼べるバインディングを自動生成する。
**実装が1つ**になるため、クロスプラットフォームのアルゴリズム一致を構造的に保証できる。

- **公開方法**: 属性マクロで Rust 側に印を付ける。
  - `#[derive(uniffi::Record)]`: 値オブジェクト(構造体)。Swift の struct / Kotlin の data class へ。
  - `#[derive(uniffi::Object)]`: 参照型・メソッドを持つクラス。`Arc<Self>` で返す。
  - `#[derive(uniffi::Error)]`: 例外型。Swift は `throws`、Kotlin は例外へ。
  - `#[uniffi::export]`: 関数や impl ブロックを公開。
- **制約**: 公開する Object は `Send + Sync` でなければならない → 内部可変性は `Mutex` 等で包む。
- **生成物**: iOS は XCFramework(`staticlib`)、Android は `.so`(`cdylib`)+ Kotlin ラッパ。
- **非同期**: `async fn` も export 可能(Swift の async / Kotlin の suspend に対応)。

## E. クロスプラットフォーム一致を「構造的に」保証する原則

本設計が一致を保証できているのは、以下を徹底しているため。

1. **OS 内蔵 ICU に依存しない**: iOS の `applyingTransform` も Android の
   `android.icu.Transliterator` も中身は ICU だが、**OS バージョンごとに ICU のバージョンが
   異なり結果がずれうる**。本設計は純 Rust の `unicode-normalization` を**バンドル**するため、
   正規化結果がビルド時点でバイト単位一致する。
2. **SQLite を同梱**: OS 同梱 SQLite はバージョンが端末ごとに違う(trigram は 3.34+)。
   rusqlite の `bundled` で同一バージョンを焼き込み、挙動を固定する。
3. **辞書非依存の処理だけで構成**: 正規化(NFKC・かな写像・小文字化)と trigram は
   いずれも辞書を引かない決定的処理。読み付与のような辞書依存処理を入れる場合は、
   辞書ごと Rust コアに同梱してバージョンをピン留めする(OS 機能は使わない)。
4. **ゴールデンテストで担保**: 「入力 → 期待される正規化文字列 / 期待ヒット ID」を
   共有 JSON にし、両OSの CI で同一ファイルを検証する。片方だけ静かにずれても気づける。

## F. SwiftData / Room とインデックスの同期点

- **SwiftData 永続的履歴トラッキング(iOS 18)**: 変更履歴をトークンで追跡し、前回トークン以降の
  挿入/更新/削除の差分を取得できる。`@Attribute(.preserveValueOnDeletion)` と併用すると
  削除済みレコードの情報も拾えるため、`remove(id)` 連携がきれいに書ける。
- **Room InvalidationTracker**: テーブル変更を監視するオブザーバ。変更通知を受けて該当行を
  再 index する。あるいは SQLite トリガで変更ログを溜める方式も可。
- **ID の持ち方**: `PersistentIdentifier`(SwiftData)や rowid(Room)に直接結合させず、
  アプリ側で振る安定キー(UUID 等)をエンジンの ID にすると、本体DB実装からインデックスを
  独立させられ移植性が保てる。
