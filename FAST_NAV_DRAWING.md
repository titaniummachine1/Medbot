# Fast Nav Mesh Drawing

Below is a quick reference for implementing lightweight nav-mesh visualization with chunked lookup.

| Step | Action | Purpose |
| ---- | ------ | ------- |
| **1.** | **Build `gridIndex` after `Navigation.Setup()`** using `buildGrid()` which buckets each node by `[cx][cy][cz]` where `c* = floor(pos / chunkSize)`. | Prepare a lookup table before drawing. |
| **2.** | **Store only node IDs** – `nodeCell[id] = {cx,cy,cz}`. | Avoid allocations during drawing. |
| **3.** | Expose two sliders in the menu: `chunkSize` (64‑512 uu) and `renderChunks` (Manhattan radius 1‑10). | User controls precision and range. |
| **4.** | **Per-frame** `collectVisible(me)`<br>· calculate your cell `(px,py,pz)`<br>· iterate a diamond radius of `renderChunks`<br>· copy ids from each bucket into reusable `visBuf`. | Touch only needed areas; no allocations. |
| **5.** | **Draw** using `visBuf` (`for i=1,visCount do …`). Retrieve fine points with `Node.GetAreaPoints(id)` only here. | Nothing outside the radius hits the GPU or GC. |
| **6.** | **Rebuild** the grid when the map or sliders (`chunkSize`/`renderChunks`) change. | Keeps the table consistent with settings. |

```lua
-- loader.lua
Navigation.Setup()
require("MedBot.Visuals").Initialize()   -- grid builds only once

-- Visuals.lua (extract)
local function collectVisible(me)
  visCount = 0
  local px,py,pz = worldToCell(me:GetAbsOrigin())
  local r = cfg.renderChunks
  for dx=-r,r do
    local ax = math.abs(dx)
    for dy=-(r-ax),(r-ax) do
      local dzMax = r-ax-math.abs(dy)
      for dz=-dzMax,dzMax do
        local b = gridIndex[px+dx] and gridIndex[px+dx][py+dy] and gridIndex[px+dx][py+dy][pz+dz]
        if b then
          for _,id in ipairs(b) do
            visCount=visCount+1
            visBuf[visCount]=id
          end
        end
      end
    end
  end
end
```

This approach inspects only about \~$2 r^3$ buckets instead of all nodes, avoids short-lived tables, and allows the menu to expand or shrink the range on the fly.
