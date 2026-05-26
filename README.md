# unfydqry

> 🌐 日本語版: [docs/README.ja.md](docs/README.ja.md)

A shared full-text search engine usable from iOS, Android, and Kotlin Multiplatform.
A single search core written in **Rust + UniFFI** is consumed as a SwiftPM package on
iOS, as a Gradle module on Android, and as a KMP library sharing a common Kotlin API.

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
├── kmp/                         Kotlin Multiplatform library
│   ├── lib/src/commonMain/       expect SearchEngine + Hit (common API)
│   ├── lib/src/androidMain/      actual → uniffi.unfydqry.SearchEngine (compile-time dep)
│   ├── lib/src/iosMain/          actual → @objc Swift bridge → UnifiedQuery (compile-time dep)
│   ├── ios_bridge/
│   │   ├── UnfydqryBridge.swift  only file to maintain for iOS bridge
│   │   └── UnfydqryBridge.h      auto-generated (run generate_bridge_header.sh)
│   ├── lib/src/commonTest/       11 shared conformance tests
│   └── sample/androidApp/        KMP Compose sample app
└── docs/
    ├── README.ja.md
    └── cross-platform-search-engine-design.md
```

| | iOS | Android | KMP |
|---|---|---|---|
| Library | `import UnifiedQuery` (SwiftPM) | `implementation(project(":unifiedquery"))` | `project(":lib")` |
| Native binding dep | `UnifiedQuery.SearchEngine` | `uniffi.unfydqry.SearchEngine` | same (via actual) |
| FFI | XCFramework → Rust | JNA `.so` → Rust | cinterop → ObjC bridge → Rust |

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

### Kotlin Multiplatform (common)
```kotlin
import unfydqry.kmp.SearchEngine

val engine = SearchEngine(dbPath)   // identical API on Android and iOS
engine.index(1L, "Ｐｙｔｈｏｮ 入門")
val hits = engine.search("python")  // → [Hit(id=1, score=-1.521)]
engine.close()
```

`SearchEngine.android.kt` delegates to `uniffi.unfydqry.SearchEngine`; if the Kotlin
binding's API changes the actual will fail to compile.  On iOS, `UnfydqryBridge.swift`
wraps `UnifiedQuery.SearchEngine` directly — the same guarantee holds.

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
# Build the static libs that feed the XCFramework
cd core && cargo build --release \
  --target aarch64-apple-darwin \
  --target aarch64-apple-ios \
  --target aarch64-apple-ios-sim \
  --target x86_64-apple-ios
# (optional) regenerate the Swift binding
cargo run --bin uniffi-bindgen -- generate \
  --library target/aarch64-apple-ios/release/libunfydqry.a \
  --language swift --out-dir generated/swift

# An end-to-end script that bundles the above into a fat XCFramework
# would live at scripts/build-xcframework.sh.
cd ..

# Tests
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

### Kotlin Multiplatform
```sh
# 1. Build the ObjC bridge header from Swift (first time / after API change).
./kmp/scripts/generate_bridge_header.sh

# 2. Android instrumented tests (device/emulator required)
cd kmp && ./gradlew :lib:connectedAndroidTest  # 11 cases

# 3. iOS Kotlin/Native framework
./gradlew :lib:linkDebugFrameworkIosSimulatorArm64

# 4. Android sample app
./gradlew :sample:androidApp:assembleDebug
```

When the iOS binding (`UnifiedQuery.SearchEngine`) changes its API:
1. Update `kmp/ios_bridge/UnfydqryBridge.swift`
2. Run `./kmp/scripts/generate_bridge_header.sh`
3. Commit both files — the KMP `iosMain` will surface any compile errors.

## Tests

| Runtime | Scope | Command | Count |
|---|---|---|---|
| Rust | Internal `normalize` / `engine` logic | `cd core && cargo test --lib` | 15 |
| Swift Testing | Full public API on macOS / iOS simulator | `swift test` | 61 |
| JUnit 5 (JVM) | The same scenarios re-validated from Kotlin | `cd android/sample && gradle :unifiedquery:test` | 95 |
| KMP (Android instrumented) | KMP public API on real Android device | `cd kmp && ./gradlew :lib:connectedAndroidTest` | 11 |

`ios/Tests/UnifiedQueryTests/CrossPlatformGoldenTests.swift` and
`android/sample/unifiedquery/src/test/kotlin/.../CrossPlatformGoldenTest.kt` share the
**same normalization trace table and query matrix**, so any drift in the Rust core's
normalization breaks both at once (the "golden tests" approach from §E.4 of the design doc).

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
| KMP library | `:lib` / `unfydqry.kmp` |
| KMP iOS bridge | `UnfydqryBridge` (Swift `@objc`) |

## License

MIT — see [LICENSE](LICENSE).
