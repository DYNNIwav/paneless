import Cocoa

// MARK: - Private CGS/SLS API Declarations
// These are the same private APIs used by Amethyst/yabai/rift.
// They work on macOS Sequoia without SIP disabled.

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ conn: CGSConnectionID) -> CFArray

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ conn: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ conn: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ conn: CGSConnectionID) -> CGSSpaceID

// Space switching APIs
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ conn: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

@_silgen_name("CGSShowSpaces")
func CGSShowSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

@_silgen_name("CGSHideSpaces")
func CGSHideSpaces(_ conn: CGSConnectionID, _ spaces: CFArray)

// Display UUID for a given space
@_silgen_name("CGSCopyManagedDisplayForSpace")
func CGSCopyManagedDisplayForSpace(_ conn: CGSConnectionID, _ space: CGSSpaceID) -> CFString

// Window alpha — works on any window (same approach as yabai)
// NOTE: The C API uses `float` (32-bit), NOT CGFloat/Double (64-bit on ARM64)
@discardableResult
@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CGSConnectionID, _ wid: CGWindowID, _ alpha: Float) -> CGError

// Window z-ordering — order OUR window relative to ANY window
// order: 1 = above, -1 = below, 0 = out (hide)
@discardableResult
@_silgen_name("CGSOrderWindow")
func CGSOrderWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ order: Int32, _ relativeToWid: CGWindowID) -> CGError

// Display update batching — suppress redraws during bulk window moves
@_silgen_name("SLSDisableUpdate")
func SLSDisableUpdate(_ cid: CGSConnectionID)

@_silgen_name("SLSReenableUpdate")
func SLSReenableUpdate(_ cid: CGSConnectionID)

// GPU-composited window transform — applies visual-only affine transform.
// Same API yabai uses for smooth animations: zero AX IPC per frame,
// all visual work done by the compositor. Transform is relative to the
// window's actual position (identity = no visual offset).
@discardableResult
@_silgen_name("SLSSetWindowTransform")
func SLSSetWindowTransform(_ cid: CGSConnectionID, _ wid: CGWindowID, _ transform: CGAffineTransform) -> CGError

// Move window position directly via compositor (faster than AX for position-only moves)
@discardableResult
@_silgen_name("CGSMoveWindow")
func CGSMoveWindow(_ cid: CGSConnectionID, _ wid: CGWindowID, _ point: inout CGPoint) -> CGError

// Private AXUIElement API to get CGWindowID from an AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// Per-window brightness — compositor-level dimming (no overlays, follows window shape perfectly)
// brightness: 0.0 = black, 1.0 = normal. Applies to the window's compositor surface.
@discardableResult
@_silgen_name("CGSSetWindowListBrightness")
func CGSSetWindowListBrightness(_ cid: CGSConnectionID, _ wids: UnsafeMutablePointer<CGWindowID>,
                                 _ brightness: UnsafeMutablePointer<Float>, _ count: Int32) -> CGError
