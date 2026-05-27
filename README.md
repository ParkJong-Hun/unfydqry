# unfydqry

> 🌐 日本語版: [docs/README.ja.md](docs/README.ja.md)

A shared full-text search engine usable from both iOS (SwiftData) and Android (Room).
A single search core written in **Rust + UniFFI** is consumed as a SwiftPM package on
iOS and as a Gradle module on Android.

Design rationale lives in [`docs/cross-platform-search-engine-design.md`](docs/cross-platform-search-engine-design.md) (Japanese).

[![Swift Tests](https://github.com/0x0c/unfydqry/actions/workflows/swift-tests.yml/badge.svg)](https://github.com/0x0c/unfydqry/actions/workflows/swift-tests.yml)
[![Kotlin Tests](https://github.com/0x0c/unfydqry/actions/workflows/kotlin-tests.yml/badge.svg)](https://github.com/0x0c/unfydqry/actions/workflows/kotlin-tests.yml)
[![Rust Tests](https://github.com/0x0c/unfydqry/actions/workflows/rust-tests.yml/badge.svg)](https://github.com/0x0c/unfydqry/actions/workflows/rust-tests.yml)

## What it does

- **Fuzziness axes that get folded**: case, full-width / half-width, kana variant (katakana ↔ hiragana).
- **Dakuten / handakuten are kept distinct** (`か` and `が` are different keys).
- **SQLite FTS5 + trigram** index. Queries shorter than 3 chars fall back to `LIKE`.
- Searches return only the stable `id` and a `bm25` score; the host re-fetches records from its source-of-truth store.
- Because the logic lives in **one Rust implementation**, iOS and Android behaviour matches by construction, not by convention.

## Layout

```
unfydqry/
├── Package.swift                ← SwiftPM entry point, kept at repo root
├── core/                        Rust implementation (crate name: unfydqry)
│   ├── Cargo.toml
│   └── src/{lib,normalize,engine,bin/uniffi-bindgen}.rs
├── ios/                         everything iOS-specific
│   ├── UnifiedQuery.xcframework  build artifact (.gitignore)
│   ├── Sources/UnifiedQuery/     SwiftPM library; binding is committed
│   ├── Tests/UnifiedQueryTests/  Swift Testing (61 cases / 5 suites)
│   └── sample/                   SwiftUI sample app (consumes the package)
├── android/
│   ├── jniLibs/                 libunfydqry.so produced by cargo-ndk (.gitignore)
│   └── sample/                  Gradle root
│       ├── settings.gradle.kts  include(":app", ":unifiedquery")
│       ├── app/                 Compose sample app
│       └── unifiedquery/        JVM Kotlin library + JUnit 5 (95 cases / 5 suites)
└── docs/
    ├── README.ja.md
    └── cross-platform-search-engine-design.md
```

| | iOS | Android |
|---|---|---|
| Library | `import UnifiedQuery` (SwiftPM) | `implementation(project(":unifiedquery"))` |
| Generated binding | `ios/Sources/UnifiedQuery/UnifiedQuery.swift` | `android/sample/unifiedquery/src/main/kotlin/uniffi/unfydqry/unfydqry.kt` |
| FFI module | `unfydqryFFI` (via the modulemap inside the XCFramework) | `libunfydqry.so` loaded through JNA |
| Distributable | `ios/UnifiedQuery.xcframework` (arm64 device + arm64/x86_64 sim + arm64 mac) | `android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libunfydqry.so` |

## Install

### iOS (Swift Package Manager)
Add the package using a tagged release:

```swift
// Package.swift
.package(url: "https://github.com/0x0c/unfydqry.git", from: "0.1.0")
```

The xcframework is **not** committed to Git. Two forms of `Package.swift`
co-exist:
- On `main` and in every PR, `Package.swift` references the xcframework by
  local path (`binaryTarget(path:)`). Local dev and the swift-tests CI build
  the xcframework into `ios/UnifiedQuery.xcframework` first and then run
  `swift test` against that local copy.
- On every release tag, `.github/workflows/release-xcframework.yml` rewrites
  `Package.swift` to `binaryTarget(url:checksum:)` pointing at the
  `UnifiedQuery.xcframework.zip` attached to that same GitHub Release, and
  tags the rewritten commit. SwiftPM consumers resolve the tag and see the
  URL form. `main` itself is never modified by the release workflow, so
  SwiftPM's manifest cache on dev machines stays consistent.

## Quick usage

### iOS (Swift)
```swift
import UnifiedQuery

let dbURL = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("search_index.sqlite")
let engine = try SearchEngine(dbPath: dbURL.path)

try engine.index(id: 1, text: "Ｐｙｔｈｏｮ 入門")
let hits = try engine.search(query: "python", limit: 50)
// → [Hit(id: 1, score: -1.521)]
```

### Android (Kotlin)
```kotlin
import uniffi.unfydqry.SearchEngine

val engine = SearchEngine(filesDir.resolve("search_index.sqlite").absolutePath)

engine.index(1L, "Ｐｙｔｈｏｮ 入門")
val hits = engine.search("python", 50u)
// → [Hit(id=1, score=-1.521)]
```

## Build

### Prerequisites
- Rust stable (via rustup)
- macOS + Xcode 26+ (for the iOS side)
- Android NDK r29+ and the Android SDK (for the Android side)
- JDK 17+ (for Gradle)

### Rust core only
```sh
cd core
cargo test --lib                 # 15 cases
cargo build --release
```

### iOS (SwiftPM + Xcode sample)
```sh
# Build for all 4 Apple targets, regenerate the Swift binding, assemble the
# fat XCFramework, zip it for SwiftPM consumption, and print the binaryTarget
# checksum. Produces ios/UnifiedQuery.xcframework{,.zip,.zip.sha256}.
bash scripts/build-xcframework.sh

# Tests (Package.swift sees the local xcframework and uses it directly)
swift test                       # 61 cases

# Sample app
cd ios/sample
xcodegen generate                # project.yml → SearchSample.xcodeproj
open SearchSample.xcodeproj
```

### Android (Gradle sample)
```sh
# Generate the .so files via cargo-ndk and place them under jniLibs/
cd core
ANDROID_NDK_HOME=/path/to/ndk cargo ndk \
  -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../android/jniLibs build --release

# JVM unit tests (load the macOS arm64 dylib through JNA)
cargo build --release --target aarch64-apple-darwin
cd ../android/sample
gradle :unifiedquery:test        # 95 cases

# Sample app
gradle :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Tests

| Runtime | Scope | Command | Count |
|---|---|---|---|
| Rust | Internal `normalize` / `engine` logic | `cd core && cargo test --lib` | 15 |
| Swift Testing | Full public API on macOS / iOS simulator | `swift test` | 61 |
| JUnit 5 (JVM) | The same scenarios re-validated from Kotlin | `cd android/sample && gradle :unifiedquery:test` | 95 |

`ios/Tests/UnifiedQueryTests/CrossPlatformGoldenTests.swift` and
`android/sample/unifiedquery/src/test/kotlin/.../CrossPlatformGoldenTest.kt` share the
**same normalization trace table and query matrix**, so any drift in the Rust core's
normalization breaks both at once (the "golden tests" approach from §E.4 of the design doc).

## Releasing a new iOS xcframework

The xcframework is shipped via GitHub Releases, not committed to Git. To cut a
new release:

1. Land all intended changes on `main`.
2. Open Actions → **Release XCFramework** → *Run workflow*, enter a tag like
   `v0.1.0`.
3. The workflow runs `scripts/build-xcframework.sh`, rewrites the
   `// --- BINARY-TARGET START/END ---` block in `Package.swift` to the URL +
   checksum form on a detached HEAD off of `main`, tags that commit with the
   version, pushes the tag (but not the branch), and publishes a Release with
   `UnifiedQuery.xcframework.zip` attached.

The tag commit's `Package.swift` is created by the same run that uploads the
asset, so SwiftPM consumers never see a tag whose checksum disagrees with the
attached zip. `main` is left unchanged.

## Namespace map

| Layer | Name |
|---|---|
| Rust crate | `unfydqry` |
| Rust lib | `libunfydqry.{a,so,dylib}` |
| UniFFI namespace | `unfydqry` |
| Swift FFI module | `unfydqryFFI` |
| SwiftPM package | `UnifiedQuery` |
| Android Gradle module | `:unifiedquery` |
| Kotlin package | `uniffi.unfydqry` |

## License

MIT — see [LICENSE](LICENSE).
