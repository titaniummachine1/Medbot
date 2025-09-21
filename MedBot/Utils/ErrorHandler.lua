--[[
MedBot Error Handling Module
Centralized error reporting and handling system
--]]

local Common = require("MedBot.Core.Common")
local Constants = require("MedBot.Utils.Constants")
local ErrorHandler = {}

-- Error types
ErrorHandler.ERROR_TYPES = {
    VALIDATION = "VALIDATION",
    RUNTIME = "RUNTIME",
    CONFIGURATION = "CONFIGURATION",
    NETWORK = "NETWORK",
    MEMORY = "MEMORY",
    PATHFINDING = "PATHFINDING",
    NAVIGATION = "NAVIGATION",
    VISUALS = "VISUALS",
    UNKNOWN = "UNKNOWN"
}

-- Error severity levels
ErrorHandler.SEVERITY = {
    LOW = "LOW",         -- Minor issues, can continue
    MEDIUM = "MEDIUM",   -- Important issues, should log
    HIGH = "HIGH",       -- Critical issues, may affect functionality
    CRITICAL = "CRITICAL" -- System-breaking issues, should halt
}

-- Error storage
local errorLog = {}
local errorCount = 0
local lastErrorTime = 0

-- ============================================================================
-- ERROR REPORTING FUNCTIONS
-- ============================================================================

---Report an error with context and severity
---@param errorType string Error type from ERROR_TYPES
---@param message string Error message
---@param context table Additional context information
---@param severity string Error severity level
---@param shouldThrow boolean Whether to throw the error (default: false)
---@return string Error ID for tracking
function ErrorHandler.Report(errorType, message, context, severity, shouldThrow)
    severity = severity or ErrorHandler.SEVERITY.MEDIUM
    shouldThrow = shouldThrow or false

    local timestamp = globals.RealTime()
    local errorId = string.format("%s_%d_%.3f", errorType, errorCount + 1, timestamp)

    local errorEntry = {
        id = errorId,
        type = errorType,
        message = message,
        context = context or {},
        severity = severity,
        timestamp = timestamp,
        stackTrace = debug.traceback()
    }

    -- Add to error log
    table.insert(errorLog, errorEntry)
    errorCount = errorCount + 1
    lastErrorTime = timestamp

    -- Log the error
    ErrorHandler.LogError(errorEntry)

    -- Throw if requested
    if shouldThrow then
        error(string.format("[%s] %s: %s", errorType, severity, message), 2)
    end

    return errorId
end

---Log an error entry to console and notifications
---@param errorEntry table Error entry data
function ErrorHandler.LogError(errorEntry)
    local color = ErrorHandler.GetSeverityColor(errorEntry.severity)

    -- Console output
    local prefix = string.format("[%s][%s] %s",
        errorEntry.type,
        errorEntry.severity,
        os.date("%H:%M:%S", errorEntry.timestamp))

    print(string.format("%s: %s", prefix, errorEntry.message))

    -- Add context info if available
    if next(errorEntry.context) then
        print("  Context: " .. ErrorHandler.FormatContext(errorEntry.context))
    end

    -- GUI notification for critical errors
    if errorEntry.severity == ErrorHandler.SEVERITY.CRITICAL then
        Common.Notify.Simple("CRITICAL ERROR", errorEntry.message, 10)
    end
end

---Get color for severity level
---@param severity string Severity level
---@return number, number, number, number R, G, B, A color values
function ErrorHandler.GetSeverityColor(severity)
    if severity == ErrorHandler.SEVERITY.LOW then
        return 255, 255, 255, 200 -- White
    elseif severity == ErrorHandler.SEVERITY.MEDIUM then
        return 255, 165, 0, 255   -- Orange
    elseif severity == ErrorHandler.SEVERITY.HIGH then
        return 255, 0, 0, 255     -- Red
    else -- CRITICAL
        return 255, 0, 255, 255   -- Magenta
    end
end

---Format context table for display
---@param context table Context data
---@return string Formatted context string
function ErrorHandler.FormatContext(context)
    local parts = {}
    for key, value in pairs(context) do
        if type(value) == "string" or type(value) == "number" then
            table.insert(parts, string.format("%s=%s", key, tostring(value)))
        elseif type(value) == "boolean" then
            table.insert(parts, string.format("%s=%s", key, value and "true" or "false"))
        elseif type(value) == "table" and #value <= 3 then
            table.insert(parts, string.format("%s=%s", key, table.concat(value, ",")))
        else
            table.insert(parts, string.format("%s=%s", key, type(value)))
        end
    end
    return table.concat(parts, ", ")
end

-- ============================================================================
-- CONVENIENCE FUNCTIONS
-- ============================================================================

---Report a validation error
---@param message string Error message
---@param context table Additional context
---@param shouldThrow boolean Whether to throw
---@return string Error ID
function ErrorHandler.ValidationError(message, context, shouldThrow)
    return ErrorHandler.Report(
        ErrorHandler.ERROR_TYPES.VALIDATION,
        message,
        context,
        ErrorHandler.SEVERITY.HIGH,
        shouldThrow
    )
end

---Report a runtime error
---@param message string Error message
---@param context table Additional context
---@param shouldThrow boolean Whether to throw
---@return string Error ID
function ErrorHandler.RuntimeError(message, context, shouldThrow)
    return ErrorHandler.Report(
        ErrorHandler.ERROR_TYPES.RUNTIME,
        message,
        context,
        ErrorHandler.SEVERITY.HIGH,
        shouldThrow
    )
end

---Report a configuration error
---@param message string Error message
---@param context table Additional context
---@param shouldThrow boolean Whether to throw
---@return string Error ID
function ErrorHandler.ConfigError(message, context, shouldThrow)
    return ErrorHandler.Report(
        ErrorHandler.ERROR_TYPES.CONFIGURATION,
        message,
        context,
        ErrorHandler.SEVERITY.MEDIUM,
        shouldThrow
    )
end

---Report a pathfinding error
---@param message string Error message
---@param context table Additional context
---@param shouldThrow boolean Whether to throw
---@return string Error ID
function ErrorHandler.PathfindingError(message, context, shouldThrow)
    return ErrorHandler.Report(
        ErrorHandler.ERROR_TYPES.PATHFINDING,
        message,
        context,
        ErrorHandler.SEVERITY.HIGH,
        shouldThrow
    )
end

---Report a memory error
---@param message string Error message
---@param context table Additional context
---@param shouldThrow boolean Whether to throw
---@return string Error ID
function ErrorHandler.MemoryError(message, context, shouldThrow)
    return ErrorHandler.Report(
        ErrorHandler.ERROR_TYPES.MEMORY,
        message,
        context,
        ErrorHandler.SEVERITY.CRITICAL,
        shouldThrow
    )
end

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

---Safe pcall wrapper with error reporting
---@param func function Function to call
---@param errorType string Error type for reporting
---@param ... any Arguments to pass to func
---@return boolean Success status
---@return any Return value or error message
function ErrorHandler.SafeCall(func, errorType, ...)
    local success, result = pcall(func, ...)

    if not success then
        ErrorHandler.Report(
            errorType or ErrorHandler.ERROR_TYPES.RUNTIME,
            "Function call failed: " .. result,
            { functionName = tostring(func) },
            ErrorHandler.SEVERITY.HIGH,
            false
        )
    end

    return success, result
end

---Retry a function with exponential backoff
---@param func function Function to retry
---@param maxAttempts number Maximum number of attempts
---@param errorType string Error type for reporting
---@param ... any Arguments to pass to func
---@return boolean Success status
---@return any Return value or error message
function ErrorHandler.Retry(func, maxAttempts, errorType, ...)
    maxAttempts = maxAttempts or Constants.ERRORS.MAX_RETRY_ATTEMPTS

    for attempt = 1, maxAttempts do
        local success, result = ErrorHandler.SafeCall(func, errorType, ...)

        if success then
            return success, result
        end

        -- Exponential backoff delay
        if attempt < maxAttempts then
            local delay = Constants.ERRORS.RETRY_DELAY * (2 ^ (attempt - 1))
            -- In a real implementation, you'd use a timer here
            -- For now, we'll just continue immediately
        end
    end

    return false, "Max retry attempts exceeded"
end

---Check if too many errors have occurred recently
---@param timeWindow number Time window in seconds
---@param maxErrors number Maximum errors allowed in time window
---@return boolean True if error rate is too high
function ErrorHandler.IsErrorRateTooHigh(timeWindow, maxErrors)
    local currentTime = globals.RealTime()
    local recentErrors = 0

    for i = #errorLog, 1, -1 do
        local errorEntry = errorLog[i]
        if currentTime - errorEntry.timestamp <= timeWindow then
            recentErrors = recentErrors + 1
        else
            break -- Since log is ordered by timestamp, we can stop here
        end
    end

    return recentErrors >= maxErrors
end

-- ============================================================================
-- ERROR LOG MANAGEMENT
-- ============================================================================

---Get all errors of a specific type
---@param errorType string Error type to filter by
---@return table Array of error entries
function ErrorHandler.GetErrorsByType(errorType)
    local filtered = {}
    for _, errorEntry in ipairs(errorLog) do
        if errorEntry.type == errorType then
            table.insert(filtered, errorEntry)
        end
    end
    return filtered
end

---Get all errors with a specific severity
---@param severity string Severity level to filter by
---@return table Array of error entries
function ErrorHandler.GetErrorsBySeverity(severity)
    local filtered = {}
    for _, errorEntry in ipairs(errorLog) do
        if errorEntry.severity == severity then
            table.insert(filtered, errorEntry)
        end
    end
    return filtered
end

---Clear old errors from the log
---@param maxAge number Maximum age in seconds (older errors will be removed)
function ErrorHandler.ClearOldErrors(maxAge)
    local currentTime = globals.RealTime()
    local newLog = {}

    for _, errorEntry in ipairs(errorLog) do
        if currentTime - errorEntry.timestamp <= maxAge then
            table.insert(newLog, errorEntry)
        end
    end

    errorLog = newLog
end

---Get error statistics
---@return table Statistics about errors
function ErrorHandler.GetStatistics()
    local stats = {
        totalErrors = #errorLog,
        errorsByType = {},
        errorsBySeverity = {},
        recentErrors = 0
    }

    local currentTime = globals.RealTime()
    local oneHourAgo = currentTime - 3600

    for _, errorEntry in ipairs(errorLog) do
        -- Count by type
        stats.errorsByType[errorEntry.type] = (stats.errorsByType[errorEntry.type] or 0) + 1

        -- Count by severity
        stats.errorsBySeverity[errorEntry.severity] = (stats.errorsBySeverity[errorEntry.severity] or 0) + 1

        -- Count recent errors
        if errorEntry.timestamp > oneHourAgo then
            stats.recentErrors = stats.recentErrors + 1
        end
    end

    return stats
end

---Print error statistics to console
function ErrorHandler.PrintStatistics()
    local stats = ErrorHandler.GetStatistics()

    print("=== Error Handler Statistics ===")
    print(string.format("Total errors logged: %d", stats.totalErrors))
    print(string.format("Recent errors (1h): %d", stats.recentErrors))

    print("\nErrors by type:")
    for typeName, count in pairs(stats.errorsByType) do
        print(string.format("  %s: %d", typeName, count))
    end

    print("\nErrors by severity:")
    for severity, count in pairs(stats.errorsBySeverity) do
        print(string.format("  %s: %d", severity, count))
    end
    print("================================")
end

-- ============================================================================
-- AUTOMATIC ERROR CLEANUP
-- ============================================================================

-- Clean up old errors periodically
local function CleanupErrors()
    ErrorHandler.ClearOldErrors(24 * 3600) -- Keep errors for 24 hours

    -- Limit total error log size
    if #errorLog > Constants.ERRORS.ERROR_LOG_SIZE then
        local excess = #errorLog - Constants.ERRORS.ERROR_LOG_SIZE
        for i = 1, excess do
            table.remove(errorLog, 1)
        end
    end
end

-- Set up periodic cleanup
callbacks.Register("Draw", "MedBot_ErrorCleanup", function()
    local currentTime = globals.RealTime()
    if currentTime - lastErrorTime > 300 then -- Every 5 minutes
        CleanupErrors()
        lastErrorTime = currentTime
    end
end)

return ErrorHandler
