---------------------------------------------------------------------------
-- Display the StatusNotifierItem menus with `awful.menu`.
--
-- This is the default `request::menu` handler of the StatusNotifierItems
-- displayed by `wibox.widget.systray`. The menus follow the `menu_*` theme
-- variables, like the other `awful.menu` menus, and support the
-- `awful.menu.menu_keys` keyboard navigation.
--
-- The entries are displayed with their icon, mnemonic (underlined), check box
-- or radio button state and submenu indicator. Disabled entries are dimmed
-- (or use `beautiful.menu_fg_disabled`). Like the other `awful.menu` menus,
-- the menu is closed with `Escape` or a right click on the menu, not by
-- clicking elsewhere.
--
-- To use another handler instead:
--
--    local sni_item = require("wibox.widget.systray.item")
--    sni_item.disconnect_signal("request::menu",
--        awful.statusnotifier.menu.default)
--    sni_item.connect_signal("request::menu", my_handler)
--
-- See `awful.statusnotifier.gtk_menu` to use GTK menus instead.
--
-- @author WooParadog
-- @copyright 2026 WooParadog
-- @module awful.statusnotifier.menu
---------------------------------------------------------------------------

local lgi = require("lgi")
local GdkPixbuf = lgi.GdkPixbuf
local gstring = require("gears.string")
local gcolor = require("gears.color")
local gsurface = require("gears.surface")
local beautiful = require("beautiful")
local wibox = require("wibox")
local amenu = require("awful.menu")
local ascreen = require("awful.screen")
local sni_item = require("wibox.widget.systray.item")
local icon = require("wibox.widget.systray.icon")
local dpi = beautiful.xresources.apply_dpi

local capi = { awesome = awesome }

local module = {}

--- The color of the disabled StatusNotifierItem menu entries.
--
-- When not set, the disabled entries are drawn with half opacity.
--
-- @beautiful beautiful.menu_fg_disabled
-- @tparam[opt=nil] color|nil menu_fg_disabled

--- Convert a dbusmenu label (with `_` mnemonics) to Pango markup.
-- @tparam string label The label.
-- @treturn string The markup.
-- @treturn string|nil The access key.
-- @staticfct awful.statusnotifier.menu.parse_label
function module.parse_label(label)
    local key
    local ret = {}
    local i = 1

    while i <= #label do
        local c = label:sub(i, i)

        if c == "_" then
            local n = label:sub(i + 1, i + 1)

            if n == "_" then
                table.insert(ret, "_")
                i = i + 2
            elseif n ~= "" and not key then
                -- Keep multi-byte UTF-8 characters intact.
                local char = label:match("^[^\128-\191][\128-\191]*", i + 1)
                key = char:lower()
                table.insert(ret, "<u>" .. gstring.xml_escape(char) .. "</u>")
                i = i + 1 + #char
            else
                i = i + 1
            end
        else
            table.insert(ret, gstring.xml_escape(c))
            i = i + 1
        end
    end

    return table.concat(ret), key
end

-- Load the `icon-data` of an entry (PNG data).
local function surface_from_data(data)
    if not data or #data == 0 then return nil end

    local ok, pixbuf = pcall(function()
        local loader = GdkPixbuf.PixbufLoader()
        loader:write(data)
        loader:close()
        return loader:get_pixbuf()
    end)

    if not (ok and pixbuf) then return nil end

    return gsurface.load_uncached_silently(
        capi.awesome.pixbuf_to_surface(pixbuf._native, "dbusmenu")
    )
end

-- Create a separator entry for `awful.menu`.
local function separator_entry(_, args)
    local height = args.theme.separator_height or dpi(7)

    return {
        widget = wibox.widget {
            {
                orientation   = "horizontal",
                forced_height = height,
                color         = args.theme.separator_color,
                span_ratio    = 0.9,
                thickness     = dpi(1),
                widget        = wibox.widget.separator,
            },
            strategy = "exact",
            height   = height,
            widget   = wibox.container.constraint,
        },
        height = height,
        width  = args.theme.width,
        akey   = nil,
        cmd    = nil,
    }
end

local toggle_glyphs = {
    checkmark = { [true] = "☑", [false] = "☐" },
    radio     = { [true] = "◉", [false] = "○" },
}

-- Create a regular entry for `awful.menu`. This is similar to
-- `awful.menu.entry`, but supports toggles, disabled entries and a dynamic
-- width.
local function standard_entry(_, args)
    local theme = args.theme
    local height = theme.height
    local props = args.node.props

    local markup, key = module.parse_label(props.label)

    local label = wibox.widget.textbox()
    label:set_font(theme.font)
    label:set_markup(markup)

    -- The icon column: either a toggle glyph or an icon.
    local icon_widget
    local toggle = toggle_glyphs[props["toggle-type"]]

    if toggle then
        icon_widget = wibox.widget {
            markup = gstring.xml_escape(toggle[props["toggle-state"] == 1]),
            align  = "center",
            font   = theme.font,
            widget = wibox.widget.textbox,
        }
    else
        local img

        if props["icon-data"] and props["icon-data"] ~= "" then
            img = surface_from_data(props["icon-data"])
        end

        if (not img) and props["icon-name"] ~= "" then
            img = icon.lookup(props["icon-name"], args.icon_theme_path, height)
        end

        if img then
            local symbolic = type(img) == "string" and icon.is_symbolic(img)

            icon_widget = wibox.widget {
                image      = img,
                resize     = true,
                stylesheet = symbolic and icon.symbolic_stylesheet(
                    (gcolor.to_rgba_string(theme.fg_normal, "#ffffff")):sub(1, 7)
                ) or nil,
                widget     = wibox.widget.imagebox,
            }
        end
    end

    local submenu

    if type(args.cmd) == "table" then
        if theme.submenu_icon then
            submenu = wibox.widget.imagebox(theme.submenu_icon)
        else
            submenu = wibox.widget.textbox()
            submenu:set_font(theme.font)
            submenu:set_text(theme.submenu)
        end
    end

    local widget = wibox.widget {
        {
            {
                {
                    icon_widget,
                    strategy = "exact",
                    width    = height,
                    height   = height,
                    widget   = wibox.container.constraint,
                },
                {
                    label,
                    left   = dpi(4),
                    right  = dpi(8),
                    widget = wibox.container.margin,
                },
                layout = wibox.layout.fixed.horizontal,
            },
            nil,
            submenu,
            layout = wibox.layout.align.horizontal,
        },
        strategy = "exact",
        height   = height,
        widget   = wibox.container.constraint,
    }

    -- Compute the width needed by the label.
    local label_w = label:get_preferred_size(args.screen or ascreen.focused())
    local submenu_w = submenu and height or 0
    local width = math.max(theme.width, height + dpi(12) + label_w + submenu_w)

    local ret = {
        label  = label,
        icon   = icon_widget,
        widget = widget,
        cmd    = args.cmd,
        akey   = key,
        width  = width,
        height = height,
    }

    if not props.enabled then
        local fg = beautiful.menu_fg_disabled

        if fg then
            ret.widget = wibox.container.background(widget)
            ret.widget.fg = fg
        else
            widget.opacity = 0.5
        end

        ret.cmd = nil
        ret.akey = nil
    end

    return ret
end

local function make_items(menu, node, args)
    local items = {}

    for _, child in ipairs(node.children) do
        local props = child.props

        if props.visible then
            if props.type == "separator" then
                -- Skip leading and repeated separators.
                local last = items[#items]
                if last and last.new ~= separator_entry then
                    table.insert(items, { new = separator_entry })
                end
            else
                local cmd

                if props.enabled then
                    if props["children-display"] == "submenu" then
                        cmd = make_items(menu, child, args)
                    else
                        local id = child.id
                        cmd = function()
                            menu:activate(id)
                            return false
                        end
                    end
                end

                table.insert(items, {
                    new             = standard_entry,
                    node            = child,
                    cmd             = cmd,
                    icon_theme_path = args.icon_theme_path,
                    screen          = args.screen,
                })
            end
        end
    end

    -- Skip the trailing separator.
    if items[#items] and items[#items].new == separator_entry then
        table.remove(items)
    end

    items.layout = wibox.layout.fixed.vertical

    return items
end

--- Build an `awful.menu` from a parsed dbusmenu layout.
-- @tparam wibox.widget.systray.dbusmenu menu The menu (to send the events).
-- @tparam table layout The root node of the layout.
-- @treturn awful.menu The menu.
-- @staticfct awful.statusnotifier.menu.build
function module.build(menu, layout)
    return amenu(make_items(menu, layout, {
        icon_theme_path = menu.icon_theme_path,
        screen          = ascreen.focused(),
    }))
end

-- The displayed menu: { menu = dbusmenu, awful_menu = awful.menu }.
local current = nil

--- Hide the displayed StatusNotifierItem menu, if any.
-- @staticfct awful.statusnotifier.menu.hide
-- @noreturn
function module.hide()
    if current then
        current.awful_menu:hide()
    end
end

--- Get the displayed StatusNotifierItem menu.
-- @treturn awful.menu|nil The menu.
-- @staticfct awful.statusnotifier.menu.get_visible
function module.get_visible()
    return current and current.awful_menu or nil
end

--- The default `request::menu` handler.
--
-- Shows the menu with `awful.menu`. Only one menu is displayed at a time.
--
-- @tparam wibox.widget.systray.item item The item.
-- @tparam string context The reason.
-- @tparam table hints See `request::menu`.
-- @staticfct awful.statusnotifier.menu.default
-- @usebeautiful beautiful.menu_fg_disabled
-- @noreturn
function module.default(item, context, hints) -- luacheck: no unused args
    module.hide()

    local menu = hints.menu
    local m = module.build(menu, hints.layout)
    local displayed = { menu = menu, awful_menu = m }

    local function on_removed()
        m:hide()
    end

    menu:connect_signal("removed", on_removed)

    m.wibox:connect_signal("property::visible", function()
        if m.wibox.visible or current ~= displayed then return end

        current = nil
        menu:disconnect_signal("removed", on_removed)
        menu:closed()
    end)

    current = displayed
    m:show { coords = hints.coords }

    if not m.wibox.visible then
        -- `awful.menu` did not show the menu (for example it is empty).
        current = nil
        menu:disconnect_signal("removed", on_removed)
        return
    end

    menu:opened()
end

sni_item.connect_signal("request::menu", module.default)

return module

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
