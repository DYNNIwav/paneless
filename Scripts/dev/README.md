# Development harnesses

Small tools for checking window-manager behaviour from outside Paneless. They
read the window server and never modify anything, so they are safe to run against
a live session.

- `listwin.swift` — every on-screen window with its id, owner and frame.
- `watchall.swift` — polls at 4ms and prints every geometry change, so you can see
  what actually happened during an animation rather than what was asked for.
- `layoutcheck.sh` — opens a window repeatedly and asserts the layout is sane
  afterwards: no partial overlaps, no mixed sizes among tiled windows, nothing
  stranded at the off-screen parking corner.

Build the Swift ones with:

    swiftc -O listwin.swift -o listwin

## Why these exist

Measuring `kCGWindowBounds` tells you what was *requested*, not what was drawn.
When the question is whether something looks smooth, record video instead:

    screencapture -V 4 -x -R 0,0,3840,1620 out.mov     # 120fps
    ffmpeg -i out.mov -vf "scale=480:203,format=gray" -f rawvideo -

Then count frames that changed. Evenness of the gaps between them matters more
than their number: a run of identical 2-frame gaps looks smooth, and the same
average with gaps of 1, 3 and 5 does not.
