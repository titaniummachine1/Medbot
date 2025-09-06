# Beneficial Programming Patterns for MedBot

## 1. Guard Clauses Pattern (APPLY EVERYWHERE)
```lua
-- BAD: Nested conditions
function processNode(node)
    if node then
        if node.c then
            if node.connections then
                -- do work
            end
        end
    end
end

-- GOOD: Guard clauses
function processNode(node)
    if not node then return end
    if not node.c then return end
    if not node.connections then return end
    -- do work
end
```

## 2. Extract Method Pattern
```lua
-- BAD: 167-line createDoorForAreas function
-- GOOD: Break into focused functions
local function calculateDoorOwner(areaA, areaB)
local function findEdgeOverlap(edgeA, edgeB)
local function clampToWallClearance(door, areas)
local function validateDoorWidth(door)
```

## 3. Strategy Pattern for Door Building
```lua
local DoorStrategies = {
    horizontal = function(areaA, areaB) end,
    vertical = function(areaA, areaB) end
}

function createDoorForAreas(areaA, areaB)
    local strategy = determineStrategy(areaA, areaB)
    return DoorStrategies[strategy](areaA, areaB)
end
```

## 4. Builder Pattern for Complex Objects
```lua
local DoorBuilder = {}
function DoorBuilder:new() return setmetatable({}, {__index = self}) end
function DoorBuilder:setAreas(a, b) self.areaA, self.areaB = a, b; return self end
function DoorBuilder:calculateOverlap() -- logic here; return self end
function DoorBuilder:clampToWalls() -- logic here; return self end
function DoorBuilder:build() return self.door end

-- Usage: DoorBuilder:new():setAreas(a,b):calculateOverlap():clampToWalls():build()
```

## 5. Early Return Pattern
```lua
-- BAD: Deep nesting
function findPath(start, goal)
    if start and goal then
        local path = calculatePath(start, goal)
        if path then
            if #path > 0 then
                return path
            end
        end
    end
    return nil
end

-- GOOD: Early returns
function findPath(start, goal)
    if not start or not goal then return nil end
    
    local path = calculatePath(start, goal)
    if not path or #path == 0 then return nil end
    
    return path
end
```

## 6. Command Pattern for Connection Operations
```lua
local ConnectionCommands = {
    add = function(nodeA, nodeB) end,
    remove = function(nodeA, nodeB) end,
    mirror = function(connection) end
}

function executeConnectionCommand(command, ...)
    return ConnectionCommands[command](...)
end
```
