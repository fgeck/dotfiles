local colors = require("colors")
local settings = require("settings")
local app_icons = require("helpers.app_icons")
local log = require("helpers.log").new("workspaces")

log.info("workspaces.lua loading...")

-- Load AeroSpaceLua
local Aerospace = require("helpers.aerospace")
local aerospace = nil
local max_retries = 30
local retry_count = 0

-- Wait for AeroSpace connection with retry logic
while retry_count < max_retries do
    local success, result = pcall(function()
        return Aerospace.new()
    end)

    if success and result:is_initialized() then
        aerospace = result
        -- print("[WORKSPACES] Connected to AeroSpace successfully")
        break
    else
        -- print(string.format("[WORKSPACES] Connection attempt %d/%d failed, retrying...", retry_count + 1, max_retries))
        os.execute("sleep 0.5")
        retry_count = retry_count + 1
    end
end

if not aerospace or not aerospace:is_initialized() then
    -- print("[WORKSPACES] ERROR: Failed to connect to AeroSpace after " .. max_retries .. " attempts")
    return
end

-- Build NSScreen ID to SketchyBar display position mapping (ONCE at startup)
-- AeroSpace uses NSScreen IDs, SketchyBar uses left-to-right physical positions
local nsscreen_to_display = {}
local mapping_complete = false
local log_file = "/tmp/sketchybar_workspaces.log"

-- Debounce display_change events to prevent rapid-fire during monitor connect/disconnect
local display_change_pending = false
local DEBOUNCE_DELAY = 1.0  -- seconds

local function log_mapping(msg)
    local f = io.open(log_file, "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

-- Build the mapping synchronously at startup
local function build_monitor_mapping()
    local ok, err = pcall(function()
        log.info("build_monitor_mapping: starting")

        -- Get monitor positions (left-to-right order from aerospace)
        local monitors_output = aerospace:list_monitors()
        if not monitors_output or monitors_output == "" then
            log.warn("build_monitor_mapping: list_monitors returned empty")
            return
        end

        local monitor_names_by_position = {}
        local monitor_count = 0
        for line in monitors_output:gmatch("[^\r\n]+") do
            local position, name = line:match("(%d+)%s*|%s*(.+)")
            if position and name then
                monitor_names_by_position[name:match("^%s*(.-)%s*$")] = tonumber(position)
                monitor_count = monitor_count + 1
            end
        end
        log.debug("build_monitor_mapping: found %d monitors", monitor_count)

        -- Query workspaces to get NSScreen IDs and build the mapping
        local workspace_info = aerospace:query_workspaces()
        if not workspace_info or type(workspace_info) ~= "table" then
            log.warn("build_monitor_mapping: query_workspaces returned invalid data: %s", type(workspace_info))
            return
        end

        local processed = {}
        nsscreen_to_display = {} -- Clear old mapping
        for _, ws in ipairs(workspace_info) do
            local nsscreen_id_raw = ws["monitor-appkit-nsscreen-screens-id"]
            if nsscreen_id_raw then
                local nsscreen_id = math.floor(nsscreen_id_raw)
                local monitor_name = ws["monitor-name"] or ""
                monitor_name = monitor_name:match("^%s*(.-)%s*$")

                if not processed[nsscreen_id] and monitor_names_by_position[monitor_name] then
                    nsscreen_to_display[nsscreen_id] = monitor_names_by_position[monitor_name]
                    processed[nsscreen_id] = true
                    log_mapping(string.format("[MAPPING] NSScreen %d (%s) -> display %d", nsscreen_id, monitor_name, nsscreen_to_display[nsscreen_id]))
                end
            end
        end
        mapping_complete = true
        log_mapping("[MAPPING] Complete")
        log.info("build_monitor_mapping: completed successfully")
    end)

    if not ok then
        log.error("build_monitor_mapping FAILED: %s", tostring(err))
    end
end

-- Build mapping synchronously before anything else
build_monitor_mapping()

-- Root is used to handle event subscriptions
local root = sbar.add("item", { drawing = false })
local workspaces = {}

-- AeroSpace mode indicator
local mode_indicator = sbar.add("item", "aerospace.mode", {
    position = "left",
    icon = {
        string = "M",
        color = colors.green,
        font = {
            family = settings.font.text,
            style = settings.font.style_map["Bold"],
            size = 14.0,
        },
        padding_left = 8,
        padding_right = 8,
    },
    label = { drawing = false },
    background = {
        color = colors.bg1,
        drawing = true,
    },
})

local function update_mode_indicator()
    -- Query current mode using AeroSpaceLua API
    aerospace:list_modes(true, function(current_mode)
        -- print("[AEROSPACE MODE] Query result: [" .. current_mode .. "]")
        current_mode = current_mode:match("^%s*(.-)%s*$")
        -- print("[AEROSPACE MODE] Trimmed: [" .. current_mode .. "]")

        local icon_str = "M"
        local icon_color = colors.green

        if current_mode == "service" then
            icon_str = "S"
            icon_color = colors.yellow
        end

        -- print("[AEROSPACE MODE] Setting icon to: " .. icon_str)

        mode_indicator:set({
            icon = {
                string = icon_str,
                color = icon_color
            }
        })
    end)
end

mode_indicator:subscribe("aerospace_mode_change", function(env)
    -- print("[AEROSPACE MODE] Event received! Querying current mode...")
    update_mode_indicator()
end)

-- Initialize mode on startup
update_mode_indicator()

-- Helper function to get windows grouped by workspace with callbacks
local function withWindows(f)
    local ok, err = pcall(function()
        aerospace:list_all_windows(function(windows)
            -- Handle empty/nil response from aerospace
            if not windows or type(windows) ~= "table" then
                log.warn("withWindows: list_all_windows returned invalid data: %s", type(windows))
                return
            end

            -- Group windows by workspace
            local open_windows = {}
            for _, window in ipairs(windows) do
                local workspace = window.workspace
                local app = window["app-name"]
                if open_windows[workspace] == nil then
                    open_windows[workspace] = {}
                end
                table.insert(open_windows[workspace], app)
            end

            -- Get focused workspace
            aerospace:list_current(function(focused_workspace)
                if not focused_workspace or focused_workspace == "" then
                    log.warn("withWindows: list_current returned empty")
                    return
                end
                focused_workspace = focused_workspace:match("^%s*(.-)%s*$")

                -- Get workspace info (focused, visible, monitor)
                aerospace:query_workspaces(function(workspace_info)
                    if not workspace_info or type(workspace_info) ~= "table" then
                        log.warn("withWindows: query_workspaces returned invalid data: %s", type(workspace_info))
                        return
                    end

                    local visible_workspaces = {}
                    local workspace_monitors = {}

                    for _, ws in ipairs(workspace_info) do
                        if ws["workspace-is-visible"] then
                            table.insert(visible_workspaces, ws)
                        end
                        local nsscreen_id_raw = ws["monitor-appkit-nsscreen-screens-id"]
                        if nsscreen_id_raw then
                            local nsscreen_id = math.floor(nsscreen_id_raw)
                            local display_id = nsscreen_to_display[nsscreen_id]
                            if not display_id then
                                log_mapping(string.format("[WARNING] No mapping for NSScreen %d (ws %s, monitor %s), falling back", nsscreen_id, ws.workspace, ws["monitor-name"]))
                                display_id = nsscreen_id
                            end
                            workspace_monitors[ws.workspace] = display_id
                        end
                    end

                    local inner_ok, inner_err = pcall(f, {
                        open_windows = open_windows,
                        focused_workspace = focused_workspace,
                        visible_workspaces = visible_workspaces,
                        workspace_monitors = workspace_monitors
                    })
                    if not inner_ok then
                        log.error("withWindows callback failed: %s", tostring(inner_err))
                    end
                end)
            end)
        end)
    end)
    if not ok then
        log.error("withWindows failed: %s", tostring(err))
    end
end

local function updateWindow(workspace_index, args)
    local open_windows = args.open_windows[workspace_index]
    local focused_workspace = args.focused_workspace
    local visible_workspaces = args.visible_workspaces
    local workspace_monitors = args.workspace_monitors

    if open_windows == nil then
        open_windows = {}
    end

    local icon_line = ""
    local no_app = true
    for i, open_window in ipairs(open_windows) do
        no_app = false
        local app = open_window
        local lookup = app_icons[app]
        local icon = ((lookup == nil) and app_icons["Default"] or lookup)
        icon_line = icon_line .. " " .. icon
    end

    -- Determine if this workspace is focused
    local is_focused = workspace_index == focused_workspace

    -- Validate display ID to prevent crash on stale/invalid mappings
    local target_display = workspace_monitors[workspace_index]
    local display_valid = target_display and target_display > 0

    sbar.animate("tanh", 10.0, function()
        -- Check if this workspace is visible
        local is_visible = false
        for _, visible_ws in ipairs(visible_workspaces) do
            if workspace_index == visible_ws.workspace then
                is_visible = true
                break
            end
        end

        -- Build base properties (without display if invalid)
        local base_props = {
            drawing = true,
            icon = { highlight = is_focused },
            label = {
                string = icon_line,
                highlight = is_focused
            },
        }
        if display_valid then
            base_props.display = target_display
        end

        if no_app and is_visible then
            base_props.label.string = " —"
            workspaces[workspace_index]:set(base_props)
            return
        end

        if no_app and workspace_index ~= focused_workspace then
            workspaces[workspace_index]:set({
                drawing = false,
            })
            return
        end

        if no_app and workspace_index == focused_workspace then
            base_props.label.string = " —"
            workspaces[workspace_index]:set(base_props)
            return
        end

        workspaces[workspace_index]:set(base_props)
    end)
end

local function updateWindows()
    withWindows(function(args)
        for workspace_index, _ in pairs(workspaces) do
            updateWindow(workspace_index, args)
        end
    end)
end

local function updateWorkspaceMonitor()
    aerospace:query_workspaces(function(workspace_info)
        if not workspace_info or type(workspace_info) ~= "table" then
            log.warn("updateWorkspaceMonitor: invalid workspace_info")
            return
        end
        for _, ws in ipairs(workspace_info) do
            local space_index = ws.workspace
            local nsscreen_id_raw = ws["monitor-appkit-nsscreen-screens-id"]
            if nsscreen_id_raw then
                local nsscreen_id = math.floor(nsscreen_id_raw)
                local display_id = nsscreen_to_display[nsscreen_id] or nsscreen_id
                -- Only set display if we have a valid mapping and workspace exists
                if workspaces[space_index] and display_id and display_id > 0 then
                    workspaces[space_index]:set({
                        display = display_id,
                    })
                end
            end
        end
    end)
end

-- Initialize workspaces
aerospace:query_workspaces(function(workspace_info)
    for _, entry in ipairs(workspace_info) do
        local workspace_index = entry.workspace

        local workspace = sbar.add("item", {
            background = {
                color = colors.bg1,
                drawing = true,
            },
            click_script = "aerospace workspace " .. workspace_index .. " 2>/dev/null",
            drawing = false, -- Hide all items at first
            icon = {
                color = colors.with_alpha(colors.white, 0.3),
                drawing = true,
                font = { family = settings.font.numbers },
                highlight_color = colors.white,
                padding_left = 5,
                padding_right = 4,
                string = workspace_index
            },
            label = {
                color = colors.with_alpha(colors.white, 0.3),
                drawing = true,
                font = "sketchybar-app-font:Regular:16.0",
                highlight_color = colors.white,
                padding_left = 2,
                padding_right = 12,
                y_offset = -1,
            },
        })

        workspaces[workspace_index] = workspace
    end

    -- Initial setup
    updateWindows()
    updateWorkspaceMonitor()

    -- Helper to wrap event handlers with error handling
    local function safe_handler(event_name, handler)
        return function(env)
            local ok, err = pcall(handler, env)
            if not ok then
                log.error("EVENT HANDLER FAILED: %s - %s", event_name, tostring(err))
            end
        end
    end

    -- Subscribe to window creation/destruction events
    log.info("subscribing to aerospace_workspace_change")
    root:subscribe("aerospace_workspace_change", safe_handler("aerospace_workspace_change", function(env)
        log.info("EVENT: aerospace_workspace_change received")
        updateWindows()
    end))

    -- Subscribe to front app changes too
    root:subscribe("front_app_switched", safe_handler("front_app_switched", function()
        log.debug("EVENT: front_app_switched")
        updateWindows()
    end))

    root:subscribe("display_change", safe_handler("display_change", function()
        -- Debounce: skip if a rebuild is already pending
        if display_change_pending then
            log.info("EVENT: display_change - debounced (already pending)")
            return
        end
        display_change_pending = true
        log.info("EVENT: display_change - scheduling rebuild in %ss", DEBOUNCE_DELAY)

        sbar.exec("sleep " .. DEBOUNCE_DELAY, function()
            display_change_pending = false
            log.info("EVENT: display_change - executing rebuild")

            -- Clear stale mappings before rebuild
            nsscreen_to_display = {}
            mapping_complete = false

            build_monitor_mapping()

            -- Only proceed if mapping succeeded
            if mapping_complete then
                updateWorkspaceMonitor()
                updateWindows()
            else
                log.warn("EVENT: display_change - mapping failed, skipping updates")
            end
            log.info("EVENT: display_change - completed")
        end)
    end))

    aerospace:list_current(function(focused_workspace)
        focused_workspace = focused_workspace:match("^%s*(.-)%s*$")
        if workspaces[focused_workspace] then
            workspaces[focused_workspace]:set({
                icon = { highlight = true },
                label = { highlight = true },
            })
        end
    end)
end)
