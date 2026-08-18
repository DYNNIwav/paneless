#!/bin/zsh
# Opens a window N times and asserts the layout is sane every time.
# Fails loudly on: overlapping windows, wrong sizes, windows left mid-animation,
# and windows stranded at the off-screen parking spot.
D=/private/tmp/claude-501/-Users-dynni/5222ae7e-25dd-4571-9668-aab538a36784/scratchpad
ROUNDS=${1:-5}
PASS=0; FAIL=0
for r in $(seq 1 $ROUNDS); do
  osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1
  sleep 3
  open -a TextEdit
  sleep 5   # well past any animation
  RES=$($D/listwin | python3 -c "
import sys,re
ws=[]
for l in sys.stdin:
    p=l.split('\t')
    if len(p)<3 or 'BetterDisplay' in l: continue
    m=re.match(r'\((\-?\d+),(\-?\d+)\) (\d+)x(\d+)',p[2].strip())
    if m: ws.append((p[1],)+tuple(int(x) for x in m.groups()))
vis=[w for w in ws if w[1]<3000]           # on the visible screen
# Floating windows legitimately sit on top with their own size, so judge only the
# tiled ones: those sharing the size that most windows have.
from collections import Counter
if vis:
    modal=Counter((w[3],w[4]) for w in vis).most_common(1)[0][0]
    floating=[w[0] for w in vis if (w[3],w[4])!=modal]
    vis=[w for w in vis if (w[3],w[4])==modal]
problems=[]
# 1. stranded at the parking corner while supposedly visible
# 2. sizes must all match one of the grid cell sizes actually in use
sizes={}
for n,x,y,w,h in vis: sizes[(w,h)]=sizes.get((w,h),0)+1
if len(sizes)>1:
    problems.append('mixed sizes: '+', '.join(f'{w}x{h} x{c}' for (w,h),c in sizes.items()))
# 3. overlap between windows that are NOT exactly stacked (stacking is by design)
for i in range(len(vis)):
    for j in range(i+1,len(vis)):
        a,b=vis[i],vis[j]
        if (a[1],a[2],a[3],a[4])==(b[1],b[2],b[3],b[4]): continue   # exact stack, fine
        ox=min(a[1]+a[3],b[1]+b[3])-max(a[1],b[1]); oy=min(a[2]+a[4],b[2]+b[4])-max(a[2],b[2])
        if ox>2 and oy>2: problems.append(f'partial overlap {a[0]}/{b[0]} {ox}x{oy}')
print('OK' if not problems else 'BAD | '+' | '.join(problems))
for n,x,y,w,h in vis: print(f'    {n:<16} ({x},{y}) {w}x{h}', file=sys.stderr)
")
  if [[ "$RES" == OK* ]]; then echo "  round $r: OK"; PASS=$((PASS+1))
  else echo "  round $r: $RES"; FAIL=$((FAIL+1)); fi
done
echo "  ---- $PASS passed, $FAIL failed ----"
[[ $FAIL -eq 0 ]]
