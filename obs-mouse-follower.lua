local obs = obslua
local ffi = require("ffi")

local SCENE_NAME  = "Mouse Follower"
local SOURCE_NAME_PREFIX = "Display Follower"

ffi.cdef[[
    typedef struct { long x; long y; } POINT;
    typedef struct { long left; long top; long right; long bottom; } RECT;
    typedef void* HMONITOR;
    typedef void* HDC;
    typedef int (__stdcall *MONITORENUMPROC)(HMONITOR, HDC, RECT*, intptr_t);

    typedef struct {
        unsigned long cbSize;
        RECT  rcMonitor;
        RECT  rcWork;
        unsigned long dwFlags;
        char  szDevice[32];
    } MONITORINFOEXA;

    int GetCursorPos(POINT *lpPoint);
    int EnumDisplayMonitors(HDC, const RECT*, MONITORENUMPROC, intptr_t);
    int GetMonitorInfoA(HMONITOR, MONITORINFOEXA*);
    int GetDpiForMonitor(HMONITOR hmonitor, int dpiType, unsigned int *dpiX, unsigned int *dpiY);
]]
local user32 = ffi.load("user32")
local shcore = nil
pcall(function() shcore = ffi.load("Shcore") end)

local function query_mouse_position()
    local pt = ffi.new("POINT")
    user32.GetCursorPos(pt)
    return pt.x, pt.y
end

local function query_mouse_position_number()
    local x, y = query_mouse_position()
    return tonumber(x), tonumber(y)
end

local monitors = {}
local _enum_count = 0

local _enum_cb = ffi.cast("MONITORENUMPROC", function(hmon, hdc, rect, data)
    _enum_count = _enum_count + 1
    local info = ffi.new("MONITORINFOEXA")
    info.cbSize = ffi.sizeof("MONITORINFOEXA")
    local device = ""
    local scaleX, scaleY = 1.0, 1.0
    if user32.GetMonitorInfoA(hmon, info) ~= 0 then
        device = ffi.string(info.szDevice)
    end
    if shcore ~= nil and shcore.GetDpiForMonitor ~= nil then
        local dpiX = ffi.new("unsigned int[1]")
        local dpiY = ffi.new("unsigned int[1]")
        local MDT_EFFECTIVE_DPI = 0
        if shcore.GetDpiForMonitor(hmon, MDT_EFFECTIVE_DPI, dpiX, dpiY) == 0 then
            scaleX = tonumber(dpiX[0]) / 96.0
            scaleY = tonumber(dpiY[0]) / 96.0
        end
    end
    monitors[_enum_count] = {
        left   = rect.left,
        top    = rect.top,
        right  = rect.right,
        bottom = rect.bottom,
        device = device,
        scaleX = scaleX,
        scaleY = scaleY,
    }
    return 1
end)

local _last_monitor_count = -1

local function refresh_monitors()
    _enum_count = 0
    user32.EnumDisplayMonitors(nil, nil, _enum_cb, 0)
    for i = _enum_count + 1, #monitors do
        monitors[i] = nil
    end
    if _enum_count ~= _last_monitor_count then
        print("[Mouse Follower] Detected " .. _enum_count .. " monitor(s):")
        for i, mon in ipairs(monitors) do
            print("  Display " .. i .. ": " .. (mon.right - mon.left) .. "x" .. (mon.bottom - mon.top) .. " at " .. mon.left .. "," .. mon.top .. " [" .. (mon.device or "") .. "]")
        end
        _last_monitor_count = _enum_count
    end
end

local function get_monitor_at(x, y)
    for i, mon in ipairs(monitors) do
        if x >= mon.left and x < mon.right and y >= mon.top and y < mon.bottom then
            return i
        end
    end
    return 0
end

local function lerp(a, b, t) return a + (b - a) * t end

local function clamp(value, lo, hi)
    if value < lo then return lo end
    if value > hi then return hi end
    return value
end

local function cubic_ease_in_out(t)
    t = clamp(t, 0.0, 1.0)
    if t < 0.5 then
        return 4.0 * t * t * t
    else
        local p = -2.0 * t + 2.0
        return 1.0 - p * p * p / 2.0
    end
end

local config = {
    zoomRate         = 20,
    followRate       = 10,
    followBorder     = 5,
    showCursor       = true,
    lockSensitivity  = 500,
    displaySwitchDelayMs = 200,
    displaySwitchRectMode = "physical",
    tickIntervalMs   = 10,
    keepAspectRatio  = true,
    autoLockOnReverse = true,
}

local disabledDisplays = {}
local displayDeviceMap = {}
local state
local clamp_crop

local function get_canvas_size()
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        return tonumber(ovi.base_width) or 1920, tonumber(ovi.base_height) or 1080
    end
    return 1920, 1080
end

local function get_canvas_aspect()
    local w, h = get_canvas_size()
    if w <= 0 or h <= 0 then return nil end
    return w / h
end

local function get_display_size(displayNum)
    local mon = monitors[displayNum]
    if mon ~= nil then
        return mon.right - mon.left, mon.bottom - mon.top
    end
    return get_canvas_size()
end

local function get_smallest_display_size()
    local minW, minH
    for _, mon in ipairs(monitors) do
        local w = mon.right - mon.left
        local h = mon.bottom - mon.top
        if w > 0 and h > 0 and (minW == nil or (w * h) < (minW * minH)) then
            minW, minH = w, h
        end
    end
    return minW, minH
end

local function get_default_zoom_view_size()
    local minW, minH = get_smallest_display_size()
    local viewW = (minW or 1920) * 0.5
    local viewH = (minH or 1080) * 0.5
    local aspect = get_canvas_aspect()
    if aspect and aspect > 0 then
        if viewH <= 0 or (viewW / viewH) > aspect then
            viewH = viewW / aspect
        else
            viewW = viewH * aspect
        end
    end
    return viewW, viewH
end

local function aspect_lock_crop(left, top, right, bottom, xMax, yMax, aspect)
    if not aspect or aspect <= 0 then
        return clamp_crop(left, top, right, bottom, xMax, yMax)
    end

    local viewW = xMax - left - right
    local viewH = yMax - top - bottom
    if viewW <= 0 or viewH <= 0 then
        return clamp_crop(left, top, right, bottom, xMax, yMax)
    end

    local cx = left + viewW * 0.5
    local cy = top + viewH * 0.5
    local targetW, targetH = viewW, viewH
    local curAspect = viewW / viewH
    if curAspect > aspect then
        targetW = viewH * aspect
    elseif curAspect < aspect then
        targetH = viewW / aspect
    end

    -- Fit to display with uniform scaling so aspect is preserved.
    local fit = math.min(1.0, xMax / targetW, yMax / targetH)
    targetW = targetW * fit
    targetH = targetH * fit

    local minVisible = 4.0
    if targetW < minVisible then
        targetW = minVisible
        targetH = minVisible / aspect
    end
    if targetH < minVisible then
        targetH = minVisible
        targetW = minVisible * aspect
    end
    local fit2 = math.min(1.0, xMax / targetW, yMax / targetH)
    targetW = targetW * fit2
    targetH = targetH * fit2

    left   = cx - targetW * 0.5
    right  = xMax - (cx + targetW * 0.5)
    top    = cy - targetH * 0.5
    bottom = yMax - (cy + targetH * 0.5)

    return clamp_crop(left, top, right, bottom, xMax, yMax)
end

local function global_to_display_coords(x, y, displayNum)
    local mon = monitors[displayNum]
    if mon ~= nil then
        return x - mon.left, y - mon.top
    end
    return x, y
end

local function resolve_display(displayNum, mouseX, mouseY)
    if displayNum == 0 then
        displayNum = get_monitor_at(mouseX, mouseY)
        if displayNum > 0 and disabledDisplays[displayNum] then
            displayNum = 0
        end
    end
    return displayNum
end

local function normalize_point_to_display(mouseX, mouseY, displayNum)
    local xMax, yMax = get_display_size(displayNum)
    local x, y = global_to_display_coords(mouseX, mouseY, displayNum)
    return clamp(x, 0.0, xMax), clamp(y, 0.0, yMax), xMax, yMax
end

local function begin_follow(mx, my, xMax, yMax)
    state.followingMouse = true
    state.followStopSmoothing = false
    state.currentCameraX = mx
    state.currentCameraY = my
    state.lastMouseX = mx
    state.lastMouseY = my
    state.lastMouseMoveTime = os.clock()
    state.followLocked = false
    state.prevMouseVelX = 0.0
    state.prevMouseVelY = 0.0

    local xSize = xMax - state.currentRight - state.currentLeft
    local ySize = yMax - state.currentBottom - state.currentTop
    local halfW = xSize * 0.5
    local halfH = ySize * 0.5
    state.wantedLeft   = mx - halfW
    state.wantedRight  = xMax - (mx + halfW)
    state.wantedTop    = my - halfH
    state.wantedBottom = yMax - (my + halfH)
end

local function reset_follow_anchor(mx, my)
    state.currentCameraX = mx
    state.currentCameraY = my
    state.lastMouseX = mx
    state.lastMouseY = my
    state.lastMouseMoveTime = os.clock()
    state.followLocked = false
    state.prevMouseVelX = 0.0
    state.prevMouseVelY = 0.0
end

local function log_display_switch(displayNum)
    local mon = monitors[displayNum]
    print("[Mouse Follower] Switched to display " .. displayNum .. " [" .. ((mon and mon.device) or "") .. "]")
end

local function get_or_create_scene()
    local src = obs.obs_get_source_by_name(SCENE_NAME)
    if src ~= nil then
        local scene = obs.obs_scene_from_source(src)
        obs.obs_source_release(src)
        return scene
    end
    -- Create the scene
    local scene = obs.obs_scene_create(SCENE_NAME)
    if scene ~= nil then
        print("[Mouse Follower] Created scene: " .. SCENE_NAME)
    end
    return scene
end

local function source_name_for_display(displayNum)
    return SOURCE_NAME_PREFIX .. " " .. tostring(displayNum)
end

local function create_capture_settings(monitor_device)
    local settings = obs.obs_data_create()
    if monitor_device ~= nil and monitor_device ~= "" then
        obs.obs_data_set_string(settings, "monitor_id", monitor_device)
    end
    obs.obs_data_set_bool(settings, "capture_cursor", config.showCursor)
    return settings
end

local function set_scene_item_bounds(item)
    if item == nil then return end
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        local bounds = obs.vec2()
        bounds.x = ovi.base_width
        bounds.y = ovi.base_height
        obs.obs_sceneitem_set_bounds_type(item, obs.OBS_BOUNDS_SCALE_INNER)
        obs.obs_sceneitem_set_bounds(item, bounds)
    end
end

local function update_scene_item_source_settings(item, monitor_device)
    if item == nil then return end
    if obs.obs_sceneitem_get_source == nil then return end
    local source = obs.obs_sceneitem_get_source(item)
    if source == nil then return end
    local settings = create_capture_settings(monitor_device)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
end

local function ensure_display_source_item(scene, displayNum, monitor_device)
    local sourceName = source_name_for_display(displayNum)
    local item = obs.obs_scene_find_source(scene, sourceName)
    if item ~= nil then
        if monitor_device and monitor_device ~= "" and displayDeviceMap[displayNum] ~= monitor_device then
            update_scene_item_source_settings(item, monitor_device)
            displayDeviceMap[displayNum] = monitor_device
        end
        return item
    end

    local source = obs.obs_get_source_by_name(sourceName)
    if source == nil then
        local settings = create_capture_settings(monitor_device)
        source = obs.obs_source_create("monitor_capture", sourceName, settings, nil)
        obs.obs_data_release(settings)
        if source ~= nil then
            print("[Mouse Follower] Created source: " .. sourceName)
        end
    elseif monitor_device and monitor_device ~= "" and displayDeviceMap[displayNum] ~= monitor_device then
        local settings = create_capture_settings(monitor_device)
        obs.obs_source_update(source, settings)
        obs.obs_data_release(settings)
        displayDeviceMap[displayNum] = monitor_device
    end
    if source == nil then return nil end

    item = obs.obs_scene_add(scene, source)
    obs.obs_source_release(source)
    set_scene_item_bounds(item)
    if monitor_device and monitor_device ~= "" then
        displayDeviceMap[displayNum] = monitor_device
    end
    if item ~= nil then
        obs.obs_sceneitem_set_visible(item, false)
    end
    return item
end

local function ensure_display_sources_in_scene(scene)
    local items = {}
    for i, mon in ipairs(monitors) do
        items[i] = ensure_display_source_item(scene, i, mon.device or "")
    end
    return items
end

local function set_item_visible(item, visible)
    if item ~= nil then
        obs.obs_sceneitem_set_visible(item, visible)
    end
end

local function move_item_to_top(item)
    if item ~= nil and obs.obs_sceneitem_set_order ~= nil and obs.OBS_ORDER_MOVE_TOP ~= nil then
        obs.obs_sceneitem_set_order(item, obs.OBS_ORDER_MOVE_TOP)
    end
end

local function activate_display(items, displayNum)
    for i, item in ipairs(items) do
        set_item_visible(item, i == displayNum)
    end
    local activeItem = items[displayNum]
    move_item_to_top(activeItem)
    return activeItem
end

local function warmup_pending_display(items, activeDisplay, pendingDisplay)
    local activeItem = items[activeDisplay]
    local pendingItem = items[pendingDisplay]
    if pendingItem ~= nil then
        set_item_visible(pendingItem, true)
    end
    if activeItem ~= nil then
        set_item_visible(activeItem, true)
        move_item_to_top(activeItem)
    end
end

state = {
    currentLeft   = 0.0,
    currentTop    = 0.0,
    currentRight  = 0.0,
    currentBottom = 0.0,
    wantedLeft   = 0.0,
    wantedTop    = 0.0,
    wantedRight  = 0.0,
    wantedBottom = 0.0,
    wantsZoom    = true,
    zoomPhase    = "idle",
    zoomProgress = 0.0,
    followingMouse    = true,
    followStopSmoothing = false,
    rectangleFollowRestore = false,
    currentCameraX    = 0.0,
    currentCameraY    = 0.0,
    lastMouseX        = 0.0,
    lastMouseY        = 0.0,
    lastMouseMoveTime = 0.0,
    prevMouseVelX     = 0.0,
    prevMouseVelY     = 0.0,
    followLocked      = false,
    firstPointX = 0,
    firstPointY = 0,
    firstPointDisplay = 0,
    activeDisplay    = 0,
    pendingDisplay   = 0,
    pendingDisplayAt = 0.0,
    lastTickTime     = 0.0,
    monitorRefreshAt = 0.0,
    initialZoomApplied = false,
}

local hotkeys = {}

clamp_crop = function(left, top, right, bottom, xMax, yMax)
    if left < 0 then right = right + left; left = 0.0 end
    if right < 0 then left = left + right; right = 0.0 end
    if top < 0 then bottom = bottom + top; top = 0.0 end
    if bottom < 0 then top = top + bottom; bottom = 0.0 end
    local minVisible = 4.0
    if left + right > xMax - minVisible then
        local excess = (left + right) - (xMax - minVisible)
        left = left - excess / 2.0
        right = right - excess / 2.0
    end
    if top + bottom > yMax - minVisible then
        local excess = (top + bottom) - (yMax - minVisible)
        top = top - excess / 2.0
        bottom = bottom - excess / 2.0
    end
    return math.max(0.0, left), math.max(0.0, top), math.max(0.0, right), math.max(0.0, bottom)
end

local function set_wanted_crop_from_center(cx, cy, viewW, viewH, xMax, yMax)
    local halfW = viewW * 0.5
    local halfH = viewH * 0.5
    state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom = clamp_crop(
        cx - halfW,
        cy - halfH,
        xMax - (cx + halfW),
        yMax - (cy + halfH),
        xMax,
        yMax
    )
end

local function copy_wanted_crop_to_current()
    state.currentLeft = state.wantedLeft
    state.currentTop = state.wantedTop
    state.currentRight = state.wantedRight
    state.currentBottom = state.wantedBottom
end

local function lerp_current_crop(targetLeft, targetTop, targetRight, targetBottom, ease)
    state.currentLeft = lerp(state.currentLeft, targetLeft, ease)
    state.currentTop = lerp(state.currentTop, targetTop, ease)
    state.currentRight = lerp(state.currentRight, targetRight, ease)
    state.currentBottom = lerp(state.currentBottom, targetBottom, ease)
end

local function remap_state_between_displays(fromDisplay, toDisplay)
    if fromDisplay <= 0 or toDisplay <= 0 or fromDisplay == toDisplay then return end
    local oldMon = monitors[fromDisplay]
    local newMon = monitors[toDisplay]
    if oldMon == nil or newMon == nil then return end

    local oldW, oldH = get_display_size(fromDisplay)
    local newW, newH = get_display_size(toDisplay)
    if oldW <= 0 or oldH <= 0 or newW <= 0 or newH <= 0 then return end

    local mode = config.displaySwitchRectMode
    local sx, sy = 1.0, 1.0
    if mode == "percent" then
        sx, sy = newW / oldW, newH / oldH
    elseif mode == "physical" then
        local oldScaleX = (oldMon.scaleX and oldMon.scaleX > 0) and oldMon.scaleX or 1.0
        local oldScaleY = (oldMon.scaleY and oldMon.scaleY > 0) and oldMon.scaleY or 1.0
        local newScaleX = (newMon.scaleX and newMon.scaleX > 0) and newMon.scaleX or 1.0
        local newScaleY = (newMon.scaleY and newMon.scaleY > 0) and newMon.scaleY or 1.0
        sx, sy = newScaleX / oldScaleX, newScaleY / oldScaleY
    end
    local rescaleView = (mode == "percent" or mode == "physical")
    local canvasAspect = get_canvas_aspect()

    local function remap_crop_keep_global_axis(left, top, right, bottom)
        local oldViewW = oldW - right - left
        local oldViewH = oldH - bottom - top
        if oldViewW <= 0 or oldViewH <= 0 then
            local nl, nt, nr, nb
            if rescaleView then
                nl, nt, nr, nb = clamp_crop(left * sx, top * sy, right * sx, bottom * sy, newW, newH)
            else
                nl, nt, nr, nb = clamp_crop(left, top, right, bottom, newW, newH)
            end
            if config.keepAspectRatio then
                return aspect_lock_crop(nl, nt, nr, nb, newW, newH, canvasAspect)
            end
            return nl, nt, nr, nb
        end

        local newViewW = rescaleView and (oldViewW * sx) or oldViewW
        local newViewH = rescaleView and (oldViewH * sy) or oldViewH
        newViewW = clamp(newViewW, 4.0, newW)
        newViewH = clamp(newViewH, 4.0, newH)
        local halfNewW = newViewW * 0.5
        local halfNewH = newViewH * 0.5

        local oldCenterX = left + oldViewW * 0.5
        local oldCenterY = top + oldViewH * 0.5
        local globalCenterX = oldMon.left + oldCenterX
        local globalCenterY = oldMon.top + oldCenterY

        local targetCenterX = globalCenterX - newMon.left
        local targetCenterY = globalCenterY - newMon.top

        local newCenterX = clamp(targetCenterX, halfNewW, newW - halfNewW)
        local newCenterY = clamp(targetCenterY, halfNewH, newH - halfNewH)

        local newLeft   = newCenterX - halfNewW
        local newRight  = newW - (newCenterX + halfNewW)
        local newTop    = newCenterY - halfNewH
        local newBottom = newH - (newCenterY + halfNewH)
        local nl, nt, nr, nb = clamp_crop(newLeft, newTop, newRight, newBottom, newW, newH)
        if config.keepAspectRatio then
            return aspect_lock_crop(nl, nt, nr, nb, newW, newH, canvasAspect)
        end
        return nl, nt, nr, nb
    end

    state.currentLeft, state.currentTop, state.currentRight, state.currentBottom =
        remap_crop_keep_global_axis(state.currentLeft, state.currentTop, state.currentRight, state.currentBottom)
    state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom =
        remap_crop_keep_global_axis(state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom)

    local function remap_point_keep_global_axis(px, py)
        local gx = oldMon.left + px
        local gy = oldMon.top + py
        local nx = gx - newMon.left
        local ny = gy - newMon.top
        return clamp(nx, 0.0, newW), clamp(ny, 0.0, newH)
    end

    state.currentCameraX, state.currentCameraY = remap_point_keep_global_axis(state.currentCameraX, state.currentCameraY)
    state.lastMouseX, state.lastMouseY = remap_point_keep_global_axis(state.lastMouseX, state.lastMouseY)
end

local function update_follow(mouseX, mouseY, dt60, xMax, yMax)
    local viewW = xMax - state.wantedRight - state.wantedLeft
    local viewH = yMax - state.wantedBottom - state.wantedTop
    if viewW <= 0 or viewH <= 0 then return end

    local velX = mouseX - state.lastMouseX
    local velY = mouseY - state.lastMouseY
    local mouseMoved = math.abs(velX) > 0.5 or math.abs(velY) > 0.5

    local now = os.clock()
    if mouseMoved then
        state.lastMouseMoveTime = now
        if config.autoLockOnReverse then
            local prevVX = state.prevMouseVelX
            local prevVY = state.prevMouseVelY
            local reversed_x = (prevVX * velX < 0) and math.abs(prevVX) > 1 and math.abs(velX) > 1
            local reversed_y = (prevVY * velY < 0) and math.abs(prevVY) > 1 and math.abs(velY) > 1
            if reversed_x or reversed_y then
                state.followLocked = true
            end
        end
        state.prevMouseVelX = velX
        state.prevMouseVelY = velY
    else
        local timeSinceMove = (now - state.lastMouseMoveTime) * 1000.0
        if timeSinceMove > config.lockSensitivity then
            state.followLocked = true
        end
    end

    local recLeft   = state.wantedLeft
    local recTop    = state.wantedTop
    local recRight  = xMax - state.wantedRight
    local recBottom = yMax - state.wantedBottom
    local borderPct = math.max(0.0, config.followBorder)
    local borderPxX = (xMax * borderPct) / 100.0
    local borderPxY = (yMax * borderPct) / 100.0
    local safeBorderX = math.max(1.0, borderPxX)
    local safeBorderY = math.max(1.0, borderPxY)

    local distLeft   = mouseX - recLeft
    local distRight  = recRight - mouseX
    local distTop    = mouseY - recTop
    local distBottom = recBottom - mouseY
    local distX = math.min(distLeft, distRight)
    local distY = math.min(distTop, distBottom)
    local edgeNormX = distX / safeBorderX
    local edgeNormY = distY / safeBorderY
    local closestBorderNorm = math.min(edgeNormX, edgeNormY)

    if state.followLocked then
        if borderPct <= 0.0 or closestBorderNorm <= 1.0 then
            state.followLocked = false
        else
            return
        end
    end

    local edgeInfluence = 1.0
    if borderPct > 0.0 then
        local edgeBlend = clamp(1.0 - closestBorderNorm, 0.0, 1.0)
        edgeInfluence = 0.2 + edgeBlend * 0.8
    end

    local followEase = clamp(config.followRate / 100.0 * dt60, 0.0, 1.0) * edgeInfluence
    local scaleRateFixer = (xMax + yMax) / (viewW + viewH)
    followEase = clamp(followEase * scaleRateFixer, 0.0, 1.0)

    state.currentCameraX = lerp(state.currentCameraX, mouseX, followEase)
    state.currentCameraY = lerp(state.currentCameraY, mouseY, followEase)

    local halfW = viewW * 0.5
    local halfH = viewH * 0.5
    local newLeft   = state.currentCameraX - halfW
    local newRight  = xMax - (state.currentCameraX + halfW)
    local newTop    = state.currentCameraY - halfH
    local newBottom = yMax - (state.currentCameraY + halfH)

    state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom =
        clamp_crop(newLeft, newTop, newRight, newBottom, xMax, yMax)
end

local function update_zoom_phase(dt)
    local phase = state.zoomPhase
    if phase == "idle" or phase == "zoomed_in" then return end

    local step
    if config.zoomRate <= 0 then
        step = 1.0
    else
        step = clamp(config.zoomRate / 100.0 * dt * 60.0, 0.0, 1.0)
    end

    if phase == "zooming_in" then
        state.zoomProgress = math.min(1.0, state.zoomProgress + step)
        if state.zoomProgress >= 1.0 then state.zoomPhase = "zoomed_in" end
    elseif phase == "zooming_out" then
        state.zoomProgress = math.max(0.0, state.zoomProgress - step)
        if state.zoomProgress <= 0.0 then state.zoomPhase = "idle" end
    end
end

local function effective_crop()
    local phase = state.zoomPhase
    local progress = state.zoomProgress

    if not state.wantsZoom and phase == "idle" then
        return 0.0, 0.0, 0.0, 0.0
    end

    if phase == "zooming_in" or phase == "zooming_out" then
        local t = cubic_ease_in_out(progress)
        return lerp(0.0, state.wantedLeft, t),
               lerp(0.0, state.wantedTop, t),
               lerp(0.0, state.wantedRight, t),
               lerp(0.0, state.wantedBottom, t)
    end

    if state.wantsZoom then
        return state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom
    end

    return 0.0, 0.0, 0.0, 0.0
end

local function tick()
    local now = os.clock()
    local dt = (state.lastTickTime > 0) and (now - state.lastTickTime) or (1.0 / 60.0)
    state.lastTickTime = now
    dt = math.min(dt, 0.1)
    local dt60 = dt * 60.0

    if now >= state.monitorRefreshAt then
        refresh_monitors()
        state.monitorRefreshAt = now + 2.0
    end

    -- Get or create our scene
    local scene = get_or_create_scene()
    if scene == nil then return end

    local mouseX, mouseY = query_mouse_position_number()
    local displayNum = resolve_display(0, mouseX, mouseY)

    if state.activeDisplay > #monitors or (state.activeDisplay > 0 and disabledDisplays[state.activeDisplay]) then
        state.activeDisplay = 0
    end
    if state.pendingDisplay > #monitors then
        state.pendingDisplay = 0
    end

    local sceneItems = ensure_display_sources_in_scene(scene)
    if #sceneItems == 0 then
        state.lastMouseX = mouseX
        state.lastMouseY = mouseY
        return
    end

    if displayNum == 0 then
        if state.pendingDisplay > 0 and state.pendingDisplay ~= state.activeDisplay then
            set_item_visible(sceneItems[state.pendingDisplay], false)
        end
        state.pendingDisplay = 0
    elseif state.activeDisplay == 0 then
        state.activeDisplay = displayNum
        state.pendingDisplay = 0
        activate_display(sceneItems, displayNum)
        local initMouseX, initMouseY = global_to_display_coords(mouseX, mouseY, displayNum)
        local initXMax, initYMax = get_display_size(displayNum)
        state.currentCameraX = clamp(initMouseX, 0.0, initXMax)
        state.currentCameraY = clamp(initMouseY, 0.0, initYMax)
        state.lastMouseX = state.currentCameraX
        state.lastMouseY = state.currentCameraY
        if not state.initialZoomApplied then
            local viewW, viewH = get_default_zoom_view_size()
            viewW = clamp(viewW, 4.0, initXMax)
            viewH = clamp(viewH, 4.0, initYMax)
            set_wanted_crop_from_center(state.currentCameraX, state.currentCameraY, viewW, viewH, initXMax, initYMax)
            copy_wanted_crop_to_current()
            state.wantsZoom = true
            state.zoomPhase = "zoomed_in"
            state.zoomProgress = 1.0
            state.initialZoomApplied = true
        end
        log_display_switch(displayNum)
    elseif displayNum ~= state.activeDisplay then
        if state.pendingDisplay ~= displayNum then
            if state.pendingDisplay > 0 and state.pendingDisplay ~= state.activeDisplay then
                set_item_visible(sceneItems[state.pendingDisplay], false)
            end
            state.pendingDisplay = displayNum
            state.pendingDisplayAt = now + (config.displaySwitchDelayMs / 1000.0)
            warmup_pending_display(sceneItems, state.activeDisplay, state.pendingDisplay)
        elseif now >= state.pendingDisplayAt then
            local prevDisplay = state.activeDisplay
            state.activeDisplay = displayNum
            state.pendingDisplay = 0
            remap_state_between_displays(prevDisplay, state.activeDisplay)
            activate_display(sceneItems, displayNum)
            local switchMouseX, switchMouseY = global_to_display_coords(mouseX, mouseY, displayNum)
            local switchXMax, switchYMax = get_display_size(displayNum)
            state.lastMouseX = clamp(switchMouseX, 0.0, switchXMax)
            state.lastMouseY = clamp(switchMouseY, 0.0, switchYMax)
            log_display_switch(displayNum)
        else
            warmup_pending_display(sceneItems, state.activeDisplay, state.pendingDisplay)
        end
    else
        if state.pendingDisplay > 0 and state.pendingDisplay ~= state.activeDisplay then
            set_item_visible(sceneItems[state.pendingDisplay], false)
        end
        state.pendingDisplay = 0
    end

    local sceneItem = nil
    if state.activeDisplay > 0 then
        sceneItem = sceneItems[state.activeDisplay]
    else
        for _, item in ipairs(sceneItems) do
            set_item_visible(item, false)
        end
    end

    if sceneItem == nil then
        return
    end

    local xMax, yMax = get_display_size(state.activeDisplay)
    local localMouseX, localMouseY = global_to_display_coords(mouseX, mouseY, state.activeDisplay)
    localMouseX = clamp(localMouseX, 0.0, xMax)
    localMouseY = clamp(localMouseY, 0.0, yMax)

    if state.followingMouse then
        update_follow(localMouseX, localMouseY, dt60, xMax, yMax)
    end

    update_zoom_phase(dt)

    local effLeft, effTop, effRight, effBottom = effective_crop()
    effLeft, effTop, effRight, effBottom = clamp_crop(effLeft, effTop, effRight, effBottom, xMax, yMax)
    if config.keepAspectRatio then
        effLeft, effTop, effRight, effBottom = aspect_lock_crop(
            effLeft, effTop, effRight, effBottom, xMax, yMax, get_canvas_aspect()
        )
    end

    local useFollowSmoothing = state.followingMouse or state.followStopSmoothing
    if useFollowSmoothing then
        local followVisualEase = clamp(config.followRate / 100.0 * dt60, 0.0, 1.0)
        lerp_current_crop(effLeft, effTop, effRight, effBottom, followVisualEase)

        if state.followStopSmoothing and not state.followingMouse then
            local done =
                math.abs(state.currentLeft - effLeft) < 0.25 and
                math.abs(state.currentTop - effTop) < 0.25 and
                math.abs(state.currentRight - effRight) < 0.25 and
                math.abs(state.currentBottom - effBottom) < 0.25
            if done then
                state.followStopSmoothing = false
            end
        end
    else
        -- Zoom/rectangle transitions are controlled by zoomRate.
        local zoomEase = clamp(config.zoomRate / 100.0 * dt60, 0.0, 1.0)
        lerp_current_crop(effLeft, effTop, effRight, effBottom, zoomEase)
    end

    local crop = obs.obs_sceneitem_crop()
    crop.left   = math.floor(state.currentLeft   + 0.5)
    crop.top    = math.floor(state.currentTop    + 0.5)
    crop.right  = math.floor(state.currentRight  + 0.5)
    crop.bottom = math.floor(state.currentBottom + 0.5)
    obs.obs_sceneitem_set_crop(sceneItem, crop)

    state.lastMouseX = localMouseX
    state.lastMouseY = localMouseY
end

local function toggle_zoom(pressed)
    if pressed then return end
    if state.wantsZoom then
        state.wantsZoom = false
        state.zoomPhase = "zooming_out"
    else
        state.wantsZoom = true
        state.zoomPhase = "zooming_in"
    end
end

local function toggle_follow(pressed)
    if pressed then return end
    local mx, my = query_mouse_position_number()
    local displayNum = resolve_display(state.activeDisplay, mx, my)
    local xMax, yMax
    mx, my, xMax, yMax = normalize_point_to_display(mx, my, displayNum)

    local wasFollowing = state.followingMouse
    state.followingMouse = not state.followingMouse
    if state.followingMouse then
        begin_follow(mx, my, xMax, yMax)
        if not state.wantsZoom then
            state.wantsZoom = true
            state.zoomPhase = "zooming_in"
        end
    elseif wasFollowing then
        state.followStopSmoothing = true
    end
end

local function set_rectangle(pressed)
    local mx, my = query_mouse_position_number()
    local displayNum = resolve_display(state.activeDisplay, mx, my)
    if pressed then
        state.firstPointDisplay = displayNum
    elseif state.firstPointDisplay > 0 then
        displayNum = state.firstPointDisplay
    end
    local xMax, yMax
    mx, my, xMax, yMax = normalize_point_to_display(mx, my, displayNum)

    if pressed then
        state.firstPointX = mx
        state.firstPointY = my
        state.rectangleFollowRestore = state.followingMouse
        state.followingMouse = false
        state.followStopSmoothing = false
    else
        local fp_x = state.firstPointX
        local fp_y = state.firstPointY
        local dist = math.sqrt((mx - fp_x)^2 + (my - fp_y)^2)
        if dist > 10 then
            local x1 = math.min(fp_x, mx)
            local x2 = math.max(fp_x, mx)
            local y1 = math.min(fp_y, my)
            local y2 = math.max(fp_y, my)

            local left, top, right, bottom = clamp_crop(x1, y1, xMax - x2, yMax - y2, xMax, yMax)
            if config.keepAspectRatio then
                left, top, right, bottom = aspect_lock_crop(left, top, right, bottom, xMax, yMax, get_canvas_aspect())
            end
            state.wantedLeft, state.wantedTop, state.wantedRight, state.wantedBottom = left, top, right, bottom

            state.wantsZoom = true
            if state.zoomPhase ~= "zoomed_in" then
                state.zoomPhase = "zooming_in"
            end
        end
        if state.rectangleFollowRestore then
            state.followingMouse = true
            reset_follow_anchor(mx, my)
        end
        state.rectangleFollowRestore = false
        state.firstPointDisplay = 0
    end
end

function script_description()
    return "OBS Mouse Follower\nSmooth mouse-follow zoom with auto display switching and rectangle zoom.\nBy TIBI4.com"
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings,  "followRate",       10)
    obs.obs_data_set_default_int(settings,  "zoomRate",         20)
    obs.obs_data_set_default_int(settings,  "followBorder",     5)
    obs.obs_data_set_default_bool(settings, "showCursor",       true)
    obs.obs_data_set_default_int(settings,  "lockSensitivity",  500)
    obs.obs_data_set_default_int(settings,  "displaySwitchDelayMs", 200)
    obs.obs_data_set_default_string(settings, "displaySwitchRectMode", "physical")
    obs.obs_data_set_default_int(settings,  "tickIntervalMs",   10)
    obs.obs_data_set_default_bool(settings, "keepAspectRatio",    true)
    obs.obs_data_set_default_bool(settings, "autoLockOnReverse",  true)
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Display checkboxes
    refresh_monitors()
    for i = 1, #monitors do
        local mon = monitors[i]
        local label = string.format("Disable Display %d  (%dx%d at %d,%d)",
            i, mon.right - mon.left, mon.bottom - mon.top, mon.left, mon.top)
        obs.obs_properties_add_bool(props, "disable_display" .. i, label)
    end
    obs.obs_properties_add_bool(props, "showCursor", "Show cursor")
    obs.obs_properties_add_int(props, "followRate",  "Follow speed (%):", 0, 100, 1)
    obs.obs_properties_add_int(props, "followBorder","Follow border (%):",0, 50,  1)
    obs.obs_properties_add_int(props, "zoomRate",    "Zoom easing speed (%):", 0, 100, 1)
    obs.obs_properties_add_int(props, "lockSensitivity", "Lock sensitivity (ms):", 0, 2000, 50)
    obs.obs_properties_add_int(props, "displaySwitchDelayMs", "Display switch delay (ms):", 0, 2000, 10)
    local modeList = obs.obs_properties_add_list(
        props,
        "displaySwitchRectMode",
        "Display switch rectangle mode",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(modeList, "Keep physical size (DPI scale ratio)", "physical")
    obs.obs_property_list_add_string(modeList, "Keep rectangle size (pixels)", "pixels")
    obs.obs_property_list_add_string(modeList, "Keep rectangle coverage (%)", "percent")
    obs.obs_properties_add_int(props, "tickIntervalMs", "Tick interval (ms):", 1, 1000, 1)
    obs.obs_properties_add_bool(props, "autoLockOnReverse", "Auto-lock on direction reversal")
    obs.obs_properties_add_bool(props, "keepAspectRatio", "Keep OBS aspect ratio on rectangle select")

    return props
end

function script_update(settings)
    config.showCursor          = obs.obs_data_get_bool(settings, "showCursor")
    config.followRate          = obs.obs_data_get_int(settings,  "followRate")
    config.followBorder        = obs.obs_data_get_int(settings,  "followBorder")
    config.zoomRate            = obs.obs_data_get_int(settings,  "zoomRate")
    config.lockSensitivity     = obs.obs_data_get_int(settings,  "lockSensitivity")
    config.displaySwitchDelayMs= obs.obs_data_get_int(settings,  "displaySwitchDelayMs")
    config.displaySwitchRectMode = obs.obs_data_get_string(settings, "displaySwitchRectMode")
    if config.displaySwitchRectMode ~= "pixels" and config.displaySwitchRectMode ~= "percent" and config.displaySwitchRectMode ~= "physical" then
        config.displaySwitchRectMode = "physical"
    end
    config.tickIntervalMs      = obs.obs_data_get_int(settings, "tickIntervalMs")
    if config.tickIntervalMs < 1 then
        config.tickIntervalMs = 1
    end
    config.autoLockOnReverse   = obs.obs_data_get_bool(settings, "autoLockOnReverse")
    config.keepAspectRatio     = obs.obs_data_get_bool(settings, "keepAspectRatio")

    refresh_monitors()
    disabledDisplays = {}
    for i = 1, #monitors do
        if obs.obs_data_get_bool(settings, "disable_display" .. i) then
            disabledDisplays[i] = true
        end
    end

    local scene = get_or_create_scene()
    if scene ~= nil then
        local sceneItems = ensure_display_sources_in_scene(scene)
        for i, item in ipairs(sceneItems) do
            local mon = monitors[i]
            update_scene_item_source_settings(item, (mon and mon.device) or "")
        end
    end

    obs.timer_remove(tick)
    obs.timer_add(tick, config.tickIntervalMs)
end

function script_load(settings)
    hotkeys.toggle_follow = obs.obs_hotkey_register_frontend("hk_t_follow", "Toggle mouse follow", toggle_follow)
    hotkeys.toggle_zoom   = obs.obs_hotkey_register_frontend("hk_t_zoom",   "Toggle zoom",         toggle_zoom)
    hotkeys.rectangle     = obs.obs_hotkey_register_frontend("hk_rectangle", "Set rectangle",       set_rectangle)

    for key, id in pairs(hotkeys) do
        local save_array = obs.obs_data_get_array(settings, key)
        obs.obs_hotkey_load(id, save_array)
        obs.obs_data_array_release(save_array)
    end

    refresh_monitors()
    obs.timer_add(tick, config.tickIntervalMs)
end

function script_save(settings)
    for key, id in pairs(hotkeys) do
        local save_array = obs.obs_hotkey_save(id)
        obs.obs_data_set_array(settings, key, save_array)
        obs.obs_data_array_release(save_array)
    end
end

function script_unload()
    obs.timer_remove(tick)
    if _enum_cb ~= nil then
        pcall(function() _enum_cb:free() end)
        _enum_cb = nil
    end
end

