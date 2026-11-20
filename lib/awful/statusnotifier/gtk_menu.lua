---------------------------------------------------------------------------
-- Display the StatusNotifierItem menus as native GTK menus.
--
-- This is an optional `request::menu` handler, replacing the default
-- `awful.menu` one (`awful.statusnotifier.menu`). The menus look and behave
-- like the menus of the XEmbed tray icons (and of `snixembed`): they use the
-- GTK theme and icon theme, support press-drag-release and are closed by
-- clicking elsewhere.
--
-- To use it, add to `rc.lua`:
--
--    require("awful.statusnotifier.gtk_menu").enable()
--
-- This loads GTK 3 (through lgi) into awesome when the first menu is shown.
-- When GTK 3 is not available, the default handler is kept.
--
-- @author WooParadog
-- @copyright 2026 WooParadog
-- @module awful.statusnotifier.gtk_menu
---------------------------------------------------------------------------

local lgi = require("lgi")
local gdebug = require("gears.debug")
local gtimer = require("gears.timer")
local protected_call = require("gears.protected_call")
local sni_item = require("wibox.widget.systray.item")
local default_menu = require("awful.statusnotifier.menu")

local capi = {
    awesome      = awesome,
    mousegrabber = mousegrabber,
}

local module = {}

-- GTK is only loaded when a menu is shown for the first time.
local gtk

local function get_gtk()
    if gtk == nil then
        local ok, Gtk = pcall(lgi.require, "Gtk", "3.0")

        if ok and Gtk then
            local has_x11, GdkX11 = pcall(lgi.require, "GdkX11", "3.0")
            gtk = {
                Gtk       = Gtk,
                Gdk       = lgi.require("Gdk", "3.0"),
                GdkPixbuf = lgi.GdkPixbuf,
                GdkX11    = has_x11 and GdkX11 or nil,
            }
        else
            gdebug.print_warning("statusnotifier: GTK 3 is not available, " ..
                "the GTK menus cannot be displayed: " .. tostring(Gtk))
            gtk = false
        end
    end

    return gtk or nil
end

--- Can the GTK menus be displayed?
--
-- This requires GTK 3 (and its GObject introspection data).
--
-- @staticfct awful.statusnotifier.gtk_menu.is_supported
-- @treturn boolean
function module.is_supported()
    return get_gtk() ~= nil
end

-- Icon theme directories added to the GTK icon theme.
local added_theme_paths = {}

local function make_image(g, props, theme_path)
    local data = props["icon-data"]

    if data and data ~= "" then
        local ok, pixbuf = pcall(function()
            local loader = g.GdkPixbuf.PixbufLoader()
            loader:write(data)
            loader:close()
            return loader:get_pixbuf()
        end)

        if ok and pixbuf then
            return g.Gtk.Image.new_from_pixbuf(pixbuf)
        end
    end

    local name = props["icon-name"]

    if name and name ~= "" then
        if name:sub(1, 1) == "/" then
            return g.Gtk.Image.new_from_file(name)
        end

        if theme_path and theme_path ~= "" and not added_theme_paths[theme_path] then
            added_theme_paths[theme_path] = true
            g.Gtk.IconTheme.get_default():append_search_path(theme_path)
        end

        return g.Gtk.Image.new_from_icon_name(name, g.Gtk.IconSize.MENU)
    end
end

local build_menu

local function make_item(menu, g, node, theme_path)
    local Gtk = g.Gtk
    local props = node.props
    local toggle = props["toggle-type"]
    local mi

    if toggle == "checkmark" or toggle == "radio" then
        mi = Gtk.CheckMenuItem.new_with_mnemonic(props.label)
        mi:set_draw_as_radio(toggle == "radio")

        local state = props["toggle-state"]

        if state == 0 or state == 1 then
            -- Note: this emits `activate`, so it must be done before the
            -- signal is connected.
            mi:set_active(state == 1)
        else
            mi:set_inconsistent(true)
        end
    else
        local img = make_image(g, props, theme_path)

        if img then
            mi = Gtk.ImageMenuItem.new_with_mnemonic(props.label)
            mi:set_image(img)
            mi:set_always_show_image(true)
        else
            mi = Gtk.MenuItem.new_with_mnemonic(props.label)
        end
    end

    mi:set_sensitive(props.enabled and true or false)

    if props["children-display"] == "submenu" then
        mi:set_submenu(build_menu(menu, g, node, theme_path))
    else
        local id = node.id

        function mi.on_activate()
            protected_call(menu.activate, menu, id)
        end
    end

    return mi
end

build_menu = function(menu, g, node, theme_path)
    local gmenu = g.Gtk.Menu()
    local last_is_separator, count = true, 0

    for _, child in ipairs(node.children) do
        local props = child.props

        if props.visible then
            if props.type == "separator" then
                -- Skip leading and repeated separators.
                if not last_is_separator then
                    gmenu:append(g.Gtk.SeparatorMenuItem())
                    last_is_separator = true
                end
            else
                gmenu:append(make_item(menu, g, child, theme_path))
                last_is_separator = false
                count = count + 1
            end
        end
    end

    -- Remove the trailing separator.
    local children = gmenu:get_children()
    local last = children[#children]

    if last and last_is_separator then
        gmenu:remove(last)
    end

    gmenu:show_all()

    return gmenu, count
end

--- Build a GTK menu from a parsed dbusmenu layout.
-- @tparam wibox.widget.systray.dbusmenu menu The menu (to send the events).
-- @tparam table layout The root node of the layout.
-- @treturn Gtk.Menu|nil The GTK menu (nil without GTK or entries).
-- @staticfct awful.statusnotifier.gtk_menu.build
function module.build(menu, layout)
    local g = get_gtk()

    if not g then return nil end

    local gmenu, count = build_menu(menu, g, layout, menu.icon_theme_path)

    if count == 0 then
        gmenu:destroy()
        return nil
    end

    return gmenu
end

-- Get a timestamp for the GTK grabs. GTK needs it to know if the button
-- release which follows the click must close the menu.
local function get_time(g, menu)
    if not g.GdkX11 then return 0 end

    local ok, time = pcall(function()
        local toplevel = menu:get_toplevel()
        toplevel:realize()
        return g.GdkX11.x11_get_server_time(toplevel:get_window())
    end)

    return ok and time or 0
end

local function popup(g, menu, coords, button)
    local Gdk = g.Gdk

    -- While a mouse button is pressed over a wibox, awesome's X11 connection
    -- holds the implicit pointer grab of the button press. GTK uses its own
    -- connection, so it cannot grab the pointer and `popup_at_rect` would not
    -- show the menu.
    --
    -- `mousegrabber.stop()` is only used for its side effect: it calls
    -- `xcb_ungrab_pointer`, which also releases the implicit grab.
    -- `awesome.sync()` makes sure the X server processed the ungrab before GTK
    -- tries to grab the pointer.
    --
    -- When a Lua mousegrabber is running, it owns the grab and must not be
    -- stopped. Nothing is ungrabbed, so the GTK grab fails and the menu is
    -- not shown (see `show`).
    if not capi.mousegrabber.isrunning() then
        capi.mousegrabber.stop()
        capi.awesome.sync()
    end

    local root = Gdk.get_default_root_window()
    local event = Gdk.Event.new(Gdk.EventType.BUTTON_PRESS)
    event.button.window = root
    event.button.time = get_time(g, menu)
    event.button.button = button or 3
    event.button.x, event.button.y = coords.x, coords.y
    event.button.x_root, event.button.y_root = coords.x, coords.y

    local display = Gdk.Display.get_default()
    local seat = display and display:get_default_seat()

    if seat then
        event:set_device(seat:get_pointer())
    end

    menu:popup_at_rect(
        root,
        Gdk.Rectangle { x = coords.x, y = coords.y, width = 1, height = 1 },
        Gdk.Gravity.NORTH_WEST,
        Gdk.Gravity.NORTH_WEST,
        event
    )
end

-- The displayed menu: { menu = dbusmenu, gtk_menu = Gtk.Menu }.
local current = nil

--- Get the displayed GTK menu, if any.
-- @treturn Gtk.Menu|nil
-- @staticfct awful.statusnotifier.gtk_menu.get_visible
function module.get_visible()
    local m = current and current.gtk_menu
    return m and m:get_visible() and m or nil
end

local function close(displayed)
    if current ~= displayed then return end

    current = nil
    displayed.menu:disconnect_signal("removed", displayed.on_removed)
    displayed.gtk_menu:popdown()
    displayed.gtk_menu:destroy()
    displayed.menu:closed()
end

--- Hide the displayed GTK menu, if any.
-- @staticfct awful.statusnotifier.gtk_menu.hide
-- @noreturn
function module.hide()
    if current then close(current) end
end

--- The GTK `request::menu` handler.
--
-- When GTK 3 is not available, the application is asked to display its own
-- menu.
--
-- @tparam wibox.widget.systray.item item The item.
-- @tparam string context The reason.
-- @tparam table hints See `request::menu`.
-- @staticfct awful.statusnotifier.gtk_menu.show
-- @noreturn
function module.show(item, context, hints) -- luacheck: no unused args
    module.hide()

    local g = get_gtk()
    local menu = hints.menu
    local m = g and module.build(menu, hints.layout)

    if not m then
        item:context_menu(hints.coords.x, hints.coords.y)
        return
    end

    local displayed = { menu = menu, gtk_menu = m }

    function displayed.on_removed()
        close(displayed)
    end

    menu:connect_signal("removed", displayed.on_removed)
    current = displayed

    function m.on_deactivate()
        -- The entry is activated after the menu is deactivated, so destroy
        -- the menu later.
        gtimer.delayed_call(close, displayed)
    end

    menu:opened()
    popup(g, m, hints.coords, hints.button)

    -- GTK does not show the menu (and does not emit `deactivate`) when it
    -- cannot grab the pointer and the keyboard.
    if not m:get_visible() then
        gdebug.print_warning("statusnotifier: the menu could not be shown, " ..
            "the pointer or the keyboard is grabbed")
        close(displayed)
    end
end

local enabled = false

--- Use the GTK menus instead of the default `awful.menu` ones.
--
-- @treturn boolean Whether the GTK menus are used (false when GTK 3 is not
--  available).
-- @staticfct awful.statusnotifier.gtk_menu.enable
function module.enable()
    if enabled then return true end
    if not module.is_supported() then return false end

    enabled = true
    sni_item.disconnect_signal("request::menu", default_menu.default)
    sni_item.connect_signal("request::menu", module.show)

    return true
end

--- Use the default `awful.menu` menus again.
-- @staticfct awful.statusnotifier.gtk_menu.disable
-- @noreturn
function module.disable()
    if not enabled then return end

    enabled = false
    module.hide()
    sni_item.disconnect_signal("request::menu", module.show)
    sni_item.connect_signal("request::menu", default_menu.default)
end

return module

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
