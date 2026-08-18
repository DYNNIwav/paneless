import Cocoa
// Read-only. Tracks EVERY on-screen window's geometry so we can see whether two
// windows move in step or fall out of sync with each other.
let dur = Double(CommandLine.arguments[1])!
func snap() -> [CGWindowID:(String,CGRect)] {
    var out=[CGWindowID:(String,CGRect)]()
    guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else {return out}
    for w in l {
        guard let layer=w[kCGWindowLayer as String] as? Int, layer==0,
              let wid=w[kCGWindowNumber as String] as? CGWindowID,
              let own=w[kCGWindowOwnerName as String] as? String,
              let b=w[kCGWindowBounds as String] as? [String:CGFloat] else {continue}
        out[wid]=(own,CGRect(x:b["X"]!,y:b["Y"]!,width:b["Width"]!,height:b["Height"]!))
    }
    return out
}
let t0=CACurrentMediaTime()
var prev=snap()
var firstEvent: Double? = nil
print("watching \(prev.count) windows for \(Int(dur))s. Open a third window now.")
fflush(stdout)
while CACurrentMediaTime()-t0 < dur {
    let s=snap()
    var lines:[String]=[]
    for (wid,v) in s {
        if let old=prev[wid], old.1 != v.1 {
            lines.append(String(format:"  %-14@ %d  %.0f,%.0f %.0fx%.0f%@", v.0 as NSString, wid,
                v.1.origin.x, v.1.origin.y, v.1.width, v.1.height,
                (abs(old.1.width-v.1.width)>1 || abs(old.1.height-v.1.height)>1) ? "   <-- RESIZE" : "" as NSString))
        } else if prev[wid]==nil {
            lines.append(String(format:"  %-14@ %d  NEW  %.0f,%.0f %.0fx%.0f", v.0 as NSString, wid,
                v.1.origin.x, v.1.origin.y, v.1.width, v.1.height))
        }
    }
    if !lines.isEmpty {
        let now=CACurrentMediaTime()-t0
        if firstEvent==nil { firstEvent=now }
        print(String(format:"t=+%.0fms", (now-firstEvent!)*1000))
        for l in lines { print(l) }
        fflush(stdout)
    }
    prev=s
    usleep(4000)
}
