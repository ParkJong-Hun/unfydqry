# KMP Library

> **Advanced usage** — the KMP library wraps the iOS and Android native bindings
> behind a common `expect/actual` API. It requires both the Rust toolchain and
> Xcode/NDK to build, and is intended for teams already using Kotlin Multiplatform.
> If you only target Android or iOS, use the dedicated platform binding instead.

## Layout

```
kmp/
├── lib/
│   ├── src/commonMain/kotlin/unfydqry/kmp/
│   │   └── SearchEngine.kt          expect class + Hit + SearchException
│   ├── src/androidMain/kotlin/unfydqry/kmp/
│   │   └── SearchEngine.android.kt  actual → uniffi.unfydqry.SearchEngine
│   └── src/iosMain/
│       ├── cinterop/unfydqry_bridge.def
│       └── kotlin/unfydqry/kmp/
│           └── SearchEngine.ios.kt  actual → UnfydqryBridge (ObjC/Swift)
├── ios_bridge/
│   ├── UnfydqryBridge.swift         only file to maintain for the iOS bridge
│   └── UnfydqryBridge.h             auto-generated — do not edit by hand
├── scripts/
│   └── generate_bridge_header.sh
├── sample/
│   └── androidApp/                  Compose sample (Android only)
├── build.gradle.kts
└── settings.gradle.kts
```

## Common API

```kotlin
import unfydqry.kmp.SearchEngine
import unfydqry.kmp.Hit
import unfydqry.kmp.SearchException

val engine = SearchEngine(dbPath)   // identical on Android and iOS
engine.index(1L, "Ｐｙｔｈｏｮ 入門")
val hits: List<Hit> = engine.search("python")   // → [Hit(id=1, score=-1.521)]
engine.remove(1L)
engine.close()
```

`Hit.id` is the same stable identifier you passed to `index`. Re-fetch the full
record from your source-of-truth store.

## Native-binding dependency

Both actuals import the native binding class directly:

| Target | Import |
|---|---|
| `androidMain` | `uniffi.unfydqry.SearchEngine` |
| `iosMain` | `UnfydqryBridge.UnfydqrySearchEngine` (via cinterop) |

If the binding API changes the actual fails to compile — drift is caught at
build time, not at runtime.

## Build prerequisites

- Rust stable (rustup)
- macOS + Xcode 26+ (iOS side)
- Android NDK r29+ and Android SDK (Android side)
- JDK 17+

## Building

### 1. Build native artifacts

**iOS XCFramework** (required before `generate_bridge_header.sh`):

```sh
cd core
cargo build --release \
  --target aarch64-apple-darwin \
  --target aarch64-apple-ios \
  --target aarch64-apple-ios-sim \
  --target x86_64-apple-ios
# bundle into XCFramework — see scripts/build-xcframework.sh
```

**Android `.so` files**:

```sh
cd core
ANDROID_NDK_HOME=/path/to/ndk cargo ndk \
  -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o ../android/jniLibs build --release
```

### 2. Generate the ObjC bridge header

Run this once, and again whenever `UnfydqryBridge.swift` changes:

```sh
./kmp/scripts/generate_bridge_header.sh
```

This emits `kmp/ios_bridge/UnfydqryBridge.h`. Commit both files.

### 3. Build and run the Android sample

```sh
cd kmp
./gradlew :sample:androidApp:assembleDebug
```

### 4. Build the iOS Kotlin/Native framework

```sh
cd kmp
./gradlew :lib:linkDebugFrameworkIosSimulatorArm64
```

## Maintaining the iOS bridge

`kmp/ios_bridge/UnfydqryBridge.swift` is the only file you need to touch when
the `UnifiedQuery.SearchEngine` API changes:

1. Update `UnfydqryBridge.swift`.
2. Run `./kmp/scripts/generate_bridge_header.sh`.
3. Commit both `UnfydqryBridge.swift` and the regenerated `UnfydqryBridge.h`.

The `iosMain` actual and cinterop definition stay untouched unless the bridge
class or method names change.

## Namespace map

| Layer | Name |
|---|---|
| KMP library Gradle module | `:lib` |
| KMP Kotlin package | `unfydqry.kmp` |
| KMP sample package | `unfydqry.kmp.sample` |
| iOS bridge Swift class | `UnfydqrySearchEngine` (`@objc`) |
| iOS bridge ObjC module | `unfydqry_bridge` (cinterop) |
