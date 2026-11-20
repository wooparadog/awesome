---------------------------------------------------------------------------
-- Display the StatusNotifierItem menus.
--
-- `wibox.widget.systray` displays the StatusNotifierItems (the D-Bus tray
-- icons). When the menu of an item must be displayed, the item emits the
-- `request::menu` class signal with the menu layout, and the connected
-- handler displays it:
--
-- `awful.statusnotifier.menu.default` (the default) uses `awful.menu`, so
-- the menus follow the `menu_*` theme variables.
--
-- Any other function can be connected instead (see `request::menu`). When no
-- handler is connected, the application is asked to display its own menu.
--
-- @author WooParadog
-- @copyright 2026 WooParadog
-- @module awful.statusnotifier
---------------------------------------------------------------------------

--- Emitted (on the `wibox.widget.systray.item` class) when the menu of an
-- item must be displayed.
--
--    local sni_item = require("wibox.widget.systray.item")
--    sni_item.connect_signal("request::menu", function(item, context, hints)
--        -- Display hints.layout at hints.coords.
--    end)
--
-- The handler calls `hints.menu:opened()` once the menu is displayed,
-- `hints.menu:activate(id)` when an entry is selected and
-- `hints.menu:closed()` once the menu is closed. It hides the menu when
-- `hints.menu` emits `removed` (the item went away).
--
-- The layout nodes are `{ id = ..., props = { ... }, children = { ... } }`
-- tables. `props` has the [dbusmenu
-- properties](https://github.com/AyatanaIndicators/libdbusmenu/blob/master/libdbusmenu-glib/dbus-menu.xml)
-- (`type`, `label`, `enabled`, `visible`, `icon-name`, `icon-data`,
-- `toggle-type`, `toggle-state` and `children-display`), with their default
-- values.
--
-- @signal request::menu
-- @tparam wibox.widget.systray.item item The item.
-- @tparam string context `button` (a right click) or `activate` (a left
--  click on an item without a primary action).
-- @tparam table hints
-- @tparam table hints.menu The dbusmenu client (`opened`, `activate`,
--  `closed` and the `removed` signal).
-- @tparam table hints.layout The root node of the layout.
-- @tparam table hints.coords The position of the menu (`x` and `y`).
-- @tparam integer hints.button The mouse button which triggered the menu.
-- @classsignal

return {
    menu = require("awful.statusnotifier.menu"),
}

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
