---------------------------------------------------------------------------
-- A `com.canonical.dbusmenu` client.
--
-- StatusNotifierItems usually export their context menu using this
-- protocol. The menu layout is fetched when the menu is requested and the
-- events (clicks, opening and closing) are sent back to the application.
--
-- This module does not display anything: the item emits `request::menu` with
-- the parsed layout, and a handler displays it (see `awful.statusnotifier`).
--
-- Known limitations:
--
-- * The menu is a snapshot of the layout taken when it is shown. The
--   `LayoutUpdated` and `ItemsPropertiesUpdated` signals are not followed, so
--   an open menu is not updated when the application changes it (for example
--   the state of a toggle or a label).
-- * Lazily populated submenus are only populated one level deep: submenus
--   which only appear once their parent is populated stay empty (see
--   `fetch`).
--
-- This is a private module.
--
-- @author WooParadog
-- @copyright 2026 WooParadog
-- @module wibox.widget.systray.dbusmenu
-- @supermodule gears.object
---------------------------------------------------------------------------

local lgi = require("lgi")
local Gio, GLib = lgi.Gio, lgi.GLib
local gobject = require("gears.object")
local gtable = require("gears.table")
local gdebug = require("gears.debug")
local protected_call = require("gears.protected_call")
local icon = require("wibox.widget.systray.icon")

local dbusmenu = {}

local INTERFACE = "com.canonical.dbusmenu"

local defaults = {
    type               = "standard",
    label              = "",
    enabled            = true,
    visible            = true,
    ["icon-name"]      = "",
    ["toggle-type"]    = "",
    ["toggle-state"]   = -1,
    ["children-display"] = "",
}

--- Parse a `(ia{sv}av)` menu layout node.
-- @tparam GLib.Variant v The node.
-- @treturn table The node as `{ id = ..., props = {...}, children = {...} }`.
-- @staticfct wibox.widget.systray.dbusmenu.parse_layout
function dbusmenu.parse_layout(v)
    local node = {
        id       = math.floor(v:get_child_value(0).value),
        props    = setmetatable({}, { __index = defaults }),
        children = {},
    }

    local props = v:get_child_value(1)

    for i = 0, props:n_children() - 1 do
        local entry = props:get_child_value(i)
        local key = entry:get_child_value(0).value
        local val = entry:get_child_value(1):get_variant()

        if key == "icon-data" then
            node.props[key] = icon.variant_bytes(val)
        elseif not val:is_container() then
            -- The other used properties are basic types. Containers (like
            -- `shortcut`, an `aas`) are not used, and `.value` would return
            -- them as userdata.
            node.props[key] = val.value
        end
    end

    local children = v:get_child_value(2)

    for i = 0, children:n_children() - 1 do
        local child = children:get_child_value(i):get_variant()

        if child.type == "(ia{sv}av)" then
            table.insert(node.children, dbusmenu.parse_layout(child))
        end
    end

    return node
end

local function call(self, method, params, callback)
    self._private.connection:call(
        self.service, self.path, INTERFACE, method, params, nil,
        Gio.DBusCallFlags.NONE, -1, nil,
        function(c, res)
            local ret, err = c:call_finish(res)
            if callback then protected_call(callback, ret, err) end
        end
    )
end

--- Send an event to the application.
-- @method send_event
-- @tparam integer id The menu item id.
-- @tparam[opt="clicked"] string event The event name.
-- @noreturn
function dbusmenu:send_event(id, event)
    call(self, "Event", GLib.Variant("(isvu)", {
        id, event or "clicked", GLib.Variant("i", 0), os.time() % 4294967296
    }))
end

--- Fetch the menu layout.
--
-- `AboutToShow` is sent first, since some applications only populate their
-- menus on demand. It is then sent for every submenu which is still empty,
-- and the layout is fetched again if an application asks for it. Submenus
-- which are still empty in this second layout (for example the submenus of
-- a lazily populated submenu) are not populated.
--
-- @method fetch
-- @tparam function callback Called with the parsed root node (or nil).
-- @noreturn
function dbusmenu:fetch(callback)
    local function get_layout(cb)
        call(self, "GetLayout", GLib.Variant("(iias)", { 0, -1, {} }),
            function(ret, err)
                if not ret then
                    gdebug.print_warning("statusnotifier: GetLayout failed: " ..
                        tostring(err))
                    cb(nil)
                    return
                end

                cb(dbusmenu.parse_layout(ret:get_child_value(1)))
            end
        )
    end

    -- Lazily populated submenus are empty until `AboutToShow` is sent.
    local function populate(root)
        if not root then return callback(nil) end

        local empty = {}

        local function walk(node)
            for _, child in ipairs(node.children) do
                if child.props["children-display"] == "submenu" and
                  #child.children == 0 then
                    table.insert(empty, child.id)
                end
                walk(child)
            end
        end

        walk(root)

        if #empty == 0 then return callback(root) end

        local pending, need_update = #empty, false

        for _, id in ipairs(empty) do
            call(self, "AboutToShow", GLib.Variant("(i)", { id }), function(ret)
                if ret and ret.value[1] then need_update = true end

                pending = pending - 1

                if pending == 0 then
                    if need_update then
                        get_layout(callback)
                    else
                        callback(root)
                    end
                end
            end)
        end
    end

    -- The return value (whether an update is needed) is ignored since the
    -- layout is always fetched.
    call(self, "AboutToShow", GLib.Variant("(i)", { 0 }), function()
        get_layout(populate)
    end)
end

--- Does the layout have an entry to display?
--
-- Hidden entries and separators are not counted.
--
-- @staticfct wibox.widget.systray.dbusmenu.has_entries
-- @tparam table node The node (see `parse_layout`).
-- @treturn boolean
function dbusmenu.has_entries(node)
    for _, child in ipairs(node.children) do
        if child.props.visible and child.props.type ~= "separator" then
            return true
        end
    end

    return false
end

--- Tell the application that an entry was activated.
-- @method activate
-- @tparam integer id The entry id (`node.id`).
-- @noreturn
function dbusmenu:activate(id)
    self:send_event(id, "clicked")
end

--- Tell the application that the menu is displayed.
-- @method opened
-- @noreturn
function dbusmenu:opened()
    self:send_event(0, "opened")
end

--- Tell the application that the menu was closed.
-- @method closed
-- @noreturn
function dbusmenu:closed()
    self:send_event(0, "closed")
end

--- Stop using this menu.
--
-- The `removed` signal is emitted, so the menu handlers can hide the menu.
--
-- @method destroy
-- @noreturn
function dbusmenu:destroy()
    if self._private.destroyed then return end
    self._private.destroyed = true
    self:emit_signal("removed")
end

--- Has the menu been destroyed (for example because the item went away)?
-- @method is_destroyed
-- @treturn boolean
function dbusmenu:is_destroyed()
    return self._private.destroyed or false
end

--- Emitted when the menu is destroyed (the item went away, or changed its
-- menu). A displayed menu should be hidden.
-- @signal removed

local function new(_, connection, service, path, args)
    local self = gobject { enable_properties = false }

    args = args or {}

    rawset(self, "service", service)
    rawset(self, "path", path)

    -- The application provided icon theme path (for the `icon-name` of the
    -- entries).
    rawset(self, "icon_theme_path", args.icon_theme_path)

    self._private = {
        connection = connection,
    }

    gtable.crush(self, dbusmenu, true)

    return self
end

return setmetatable(dbusmenu, { __call = new })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
