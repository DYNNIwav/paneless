import Cocoa
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
for w in l {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
          let owner = w[kCGWindowOwnerName as String] as? String,
          let wid = w[kCGWindowNumber as String] as? CGWindowID,
          let b = w[kCGWindowBounds as String] as? [String:CGFloat] else { continue }
    print("\(wid)\t\(owner)\t(\(Int(b["X"]!)),\(Int(b["Y"]!))) \(Int(b["Width"]!))x\(Int(b["Height"]!))")
}
