// Screenshots every visible TailCat window (management window, settings, an open menu bar panel)
// of the real running app into build/captures/ via `screencapture -l`, one PNG per window.
// The app running this script (Terminal, Cursor, …) needs Screen Recording permission; without it
// the system prompt is triggered and the script exits.
// Usage (repo root): swift scripts/capture-windows.swift [out-dir]
import CoreGraphics
import Foundation

guard CGPreflightScreenCaptureAccess() else {
    CGRequestScreenCaptureAccess()
    FileHandle.standardError.write(Data("""
    需要屏幕录制权限：系统设置 › 隐私与安全性 › 屏幕与系统录音，给运行本脚本的 App 打开开关，
    然后重启该 App 再运行。

    """.utf8))
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/captures", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = all.filter { info in
    guard info[kCGWindowOwnerName as String] as? String == "TailCat",
          let bounds = info[kCGWindowBounds as String].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
    else { return false }
    // Skips the status item, which is itself a small window in the menu bar.
    return bounds.width > 80 && bounds.height > 80
}
guard !windows.isEmpty else {
    FileHandle.standardError.write(Data("没有找到可见的 TailCat 窗口：先打开管理窗口或设置窗口。\n".utf8))
    exit(2)
}

for (index, info) in windows.enumerated() {
    guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
    let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "window"
    let file = output.appendingPathComponent("\(index + 1)-\(title.replacingOccurrences(of: "/", with: "-")).png")
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    // -x: no shutter sound; -o: no window shadow; -l: this window only, even if covered.
    capture.arguments = ["-x", "-o", "-l\(id)", file.path]
    try capture.run()
    capture.waitUntilExit()
    if capture.terminationStatus == 0 { print(file.path) }
}
