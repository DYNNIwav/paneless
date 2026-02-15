import Cocoa

// MARK: - Private CGS API Declarations
// These are the same private APIs used by Amethyst/yabai.
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

// Window alpha (direct opacity without overlays)
@discardableResult
@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(_ cid: CGSConnectionID, _ wid: CGWindowID, _ alpha: CGFloat) -> CGError

// Private AXUIElement API to get CGWindowID from an AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
