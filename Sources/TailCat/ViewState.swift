import SwiftUI

/// Command Line Tools ship SwiftUI's `State` property wrapper, but `@State` resolves to a
/// macro whose plugin (`SwiftUIMacros`) is only in the full Xcode toolchain. Aliasing the
/// wrapper makes `@ViewState` expand as a property wrapper, which `swift build` can compile.
typealias ViewState = State
