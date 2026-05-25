// swift-tools-version:6.0
import PackageDescription

// クロスプラットフォーム検索エンジン(Rust + UniFFI)の Swift パッケージ。
// Rust 側のクレート名は `unfydqry`、Swift 側のパッケージ名は `UnifiedQuery` を採用する。
// Package.swift はリポジトリのルートに置きつつ、iOS 関係のソース・テスト・
// XCFramework は ios/ 配下にまとめている。
//
// `binaryTarget` で XCFramework を取り込み、`unfydqryFFI` の C モジュールが
// XCFramework 内の modulemap 経由で公開される(中身は libunfydqry.a)。
// 利用者は `import UnifiedQuery` だけで `SearchEngine` / `Hit` / `SearchError` /
// `normalizeLoose` に触れる。
//
// 注意:
// - XCFramework は monorepo 内で生成する成果物。core/ から再生成可能。
// - `ios/Sources/UnifiedQuery/UnifiedQuery.swift` は uniffi-bindgen により
//   Rust から生成されたバインディング。手で書き換えない。
let package = Package(
    name: "UnifiedQuery",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "UnifiedQuery", targets: ["UnifiedQuery"])
    ],
    targets: [
        .binaryTarget(
            name: "unfydqryFFI",
            path: "ios/UnifiedQuery.xcframework"
        ),
        .target(
            name: "UnifiedQuery",
            dependencies: ["unfydqryFFI"],
            path: "ios/Sources/UnifiedQuery"
        ),
        .testTarget(
            name: "UnifiedQueryTests",
            dependencies: ["UnifiedQuery"],
            path: "ios/Tests/UnifiedQueryTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
