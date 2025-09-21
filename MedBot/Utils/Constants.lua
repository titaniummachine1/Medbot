--[[
MedBot Constants Module
Centralized constants used across the codebase
--]]

local Constants = {}

-- ============================================================================
-- PHYSICS CONSTANTS
-- ============================================================================

---Gravity in units per second squared
Constants.GRAVITY = 800

---Player hitbox dimensions
Constants.HITBOX = {
    WIDTH = 24,
    STEP_HEIGHT = 18,
    MAX_JUMP_HEIGHT = 72,
    DUCK_JUMP_HEIGHT = 54,
    CLEARANCE_OFFSET = 34
}

---Movement constants
Constants.MOVEMENT = {
    MAX_SLOPE_ANGLE = 55,        -- Maximum climbable angle in degrees
    MIN_STEP_SIZE = 5,           -- Minimum step size in units
    PREFERRED_STEPS = 10,        -- Preferred number of steps for simulations
    TICK_RATE = 66,              -- Game tick rate
    ACCELERATION = 5.5,          -- Player acceleration
    SURFACE_FRICTION = 1.0       -- Player surface friction
}

---Navigation constants
Constants.NAVIGATION = {
    DROP_HEIGHT = 144,           -- Height to drop when fixing nodes
    GROUND_TRACE_OFFSET_START = Vector3(0, 0, 5),
    GROUND_TRACE_OFFSET_END = Vector3(0, 0, -67),
    MAX_PATH_LENGTH = 1000,      -- Maximum path length to prevent infinite loops
    CONNECTION_TIMEOUT = 5000    -- Connection processing timeout in ms
}

---Door generation constants
Constants.DOORS = {
    MIN_DOOR_WIDTH = 24,         -- Minimum door width in units
    MAX_HEIGHT_DIFFERENCE = 72,  -- Maximum height difference for connections
    WALL_CLEARANCE = 24,         -- Clearance needed from walls
    HEIGHT_TOLERANCE = 0.5       -- Height comparison tolerance
}

---Visual constants
Constants.VISUALS = {
    UP_VECTOR = Vector3(0, 0, 1),
    AREA_FILL_COLOR = { 55, 255, 155, 12 },
    AREA_OUTLINE_COLOR = { 255, 255, 255, 77 },
    CONNECTION_BIDIRECTIONAL_COLOR = { 255, 255, 0, 160 },
    CONNECTION_UNIDIRECTIONAL_COLOR = { 255, 64, 64, 160 },
    DOOR_COLOR = { 0, 180, 255, 220 },
    NODE_BOX_SIZE = 10
}

---Grid system constants
Constants.GRID = {
    DEFAULT_CHUNK_SIZE = 256,    -- Default grid chunk size
    DEFAULT_RENDER_CHUNKS = 3,   -- Default number of chunks to render
    MAX_NODES_PER_CHUNK = 1000,  -- Safety limit for nodes per chunk
    MIN_CHUNK_SIZE = 32,         -- Minimum allowed chunk size
    MAX_CHUNK_SIZE = 1024        -- Maximum allowed chunk size
}

---Pathfinding constants
Constants.PATHFINDING = {
    MAX_SEARCH_DISTANCE = 200,   -- Maximum distance for internal navigation
    MIN_CLOSE_DISTANCE = 50,     -- Minimum distance considered "close"
    NODE_SKIP_CHECK_DELAY = 22, -- Ticks between node skip checks
    NODE_SKIP_DISTANCE_CHECK_DELAY = 11, -- Ticks between distance checks
    MAX_PATH_HISTORY = 32        -- Maximum path history to keep
}

---Smart Jump constants
Constants.SMART_JUMP = {
    JUMP_FORCE = 300,            -- Jump force (velocity)
    MAX_JUMP_HEIGHT = 72,        -- Maximum jump height
    OBSTACLE_HEIGHT_TOLERANCE = 100, -- Maximum obstacle height to consider
    MIN_OBSTACLE_HEIGHT = 18     -- Minimum obstacle height to trigger jump
}

---Configuration constants
Constants.CONFIG = {
    MAX_CONFIG_SIZE = 1024 * 1024, -- Maximum config file size (1MB)
    CONFIG_BACKUP_COUNT = 5,     -- Number of config backups to keep
    AUTO_SAVE_DELAY = 5000       -- Auto-save delay in milliseconds
}

---Memory management constants
Constants.MEMORY = {
    GC_THRESHOLD = 1024 * 1024,   -- GC threshold in KB
    MAX_TABLE_SIZE = 10000,      -- Maximum table size before cleanup
    CLEANUP_INTERVAL = 1000      -- Cleanup interval in ticks
}

---Error handling constants
Constants.ERRORS = {
    MAX_RETRY_ATTEMPTS = 3,      -- Maximum retry attempts
    RETRY_DELAY = 1000,          -- Retry delay in milliseconds
    ERROR_LOG_SIZE = 1000        -- Maximum error log entries
}

---Debug constants
Constants.DEBUG = {
    MAX_DEBUG_LINES = 100,       -- Maximum debug lines to show
    DEBUG_TEXT_DURATION = 5000,  -- Debug text display duration
    PERFORMANCE_LOG_INTERVAL = 1000 -- Performance logging interval
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

---Get a constant value by path (e.g., "PHYSICS.GRAVITY")
---@param path string Dot-separated path to the constant
---@return any The constant value or nil if not found
function Constants.Get(path)
    local current = Constants
    for part in path:gmatch("([^%.]+)") do
        current = current[part]
        if not current then
            return nil
        end
    end
    return current
end

---Check if a constant exists at the given path
---@param path string Dot-separated path to the constant
---@return boolean True if the constant exists
function Constants.Has(path)
    return Constants.Get(path) ~= nil
end

---Set a constant value (for testing or runtime overrides)
---@param path string Dot-separated path to the constant
---@param value any New value for the constant
function Constants.Set(path, value)
    local parts = {}
    for part in path:gmatch("([^%.]+)") do
        table.insert(parts, part)
    end

    local current = Constants
    for i = 1, #parts - 1 do
        current[parts[i]] = current[parts[i]] or {}
        current = current[parts[i]]
    end

    current[parts[#parts]] = value
end

---Get all constants in a category
---@param category string Category name (e.g., "PHYSICS")
---@return table Table of constants in the category
function Constants.GetCategory(category)
    return Constants[category] or {}
end

---List all available categories
---@return string[] Array of category names
function Constants.GetCategories()
    local categories = {}
    for key, value in pairs(Constants) do
        if type(value) == "table" and key ~= "Get" and key ~= "Has" and key ~= "Set" and key ~= "GetCategory" and key ~= "GetCategories" then
            table.insert(categories, key)
        end
    end
    table.sort(categories)
    return categories
end

return Constants
