--##########################################################################
--  Phase3_KDTree.lua  ·  Build spatial index for fast nearest-neighbor queries
--##########################################################################

local Common = require("MedBot.Core.Common")

local Phase3_KDTree = {}

local Log = Common.Log.new("Phase3_KDTree")

--##########################################################################
--  LOCAL HELPERS
--##########################################################################

-- Simple 3D KD-tree implementation for fast nearest-neighbor search
-- Builds from nodes in G.Navigation.nodes (called after basic setup complete)

local function buildKDTree(nodes)
    -- Collect all non-door nodes into array
    local points = {}
    for id, node in pairs(nodes) do
        if not node.isDoor and node.pos then
            table.insert(points, {
                pos = node.pos,
                id = id,
                node = node,
            })
        end
    end

    if #points == 0 then
        Log:Warn("No valid nodes for KD-tree")
        return nil
    end

    -- Build tree recursively
    local function build(pointList, depth)
        if #pointList == 0 then
            return nil
        end

        -- Axis cycling: 0=x, 1=y, 2=z
        local axis = depth % 3
        local axisName = (axis == 0) and "x" or (axis == 1) and "y" or "z"

        -- Sort by current axis
        table.sort(pointList, function(a, b)
            return a.pos[axisName] < b.pos[axisName]
        end)

        local medianIdx = math.floor(#pointList / 2) + 1
        local median = pointList[medianIdx]

        -- Split into left/right
        local leftPoints = {}
        local rightPoints = {}
        for i = 1, #pointList do
            if i < medianIdx then
                table.insert(leftPoints, pointList[i])
            elseif i > medianIdx then
                table.insert(rightPoints, pointList[i])
            end
        end

        return {
            point = median,
            axis = axis,
            left = build(leftPoints, depth + 1),
            right = build(rightPoints, depth + 1),
        }
    end

    return build(points, 0)
end

--##########################################################################
--  PUBLIC API
--##########################################################################

--- Build KD-tree spatial index for all area nodes
--- Called after basic setup (nodes in global) but before door generation
--- @return table KD-tree root node
function Phase3_KDTree.Execute(nodes)
    assert(type(nodes) == "table", "Phase3_KDTree.Execute: nodes must be table")

    Log:Info("Building KD-tree spatial index")

    local tree = buildKDTree(nodes)
    if tree then
        Log:Info("Phase 3 complete: KD-tree built")
    else
        Log:Warn("Phase 3: KD-tree build failed")
    end

    return tree
end

--- Find nearest neighbor using KD-tree
--- @param tree table KD-tree root
--- @param pos Vector3 query position
--- @return table|nil nearest point {pos, id, node}
function Phase3_KDTree.FindNearest(tree, pos)
    if not tree or not pos then
        return nil
    end

    local bestDistSq = math.huge
    local best = nil

    local function search(node, depth)
        if not node then
            return
        end

        local axis = node.axis
        local axisName = (axis == 0) and "x" or (axis == 1) and "y" or "z"
        local diff = pos[axisName] - node.point.pos[axisName]
        local distSq = (node.point.pos - pos):LengthSqr()

        if distSq < bestDistSq then
            bestDistSq = distSq
            best = node.point
        end

        -- Choose branch
        local first, second
        if diff < 0 then
            first, second = node.left, node.right
        else
            first, second = node.right, node.left
        end

        search(first, depth + 1)

        -- Check if we need to search other side
        if diff * diff < bestDistSq then
            search(second, depth + 1)
        end
    end

    search(tree, 0)
    return best
end

return Phase3_KDTree
