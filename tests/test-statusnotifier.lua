-- Test the StatusNotifierItem support (the D-Bus side, without display).
--
-- A fake application is exported on a separate D-Bus connection (with its own
-- unique name) from within awesome itself.

local runner = require("_runner")
local lgi = require("lgi")
local Gio, GLib, GObject = lgi.Gio, lgi.GLib, lgi.GObject
local gdebug = require("gears.debug")
local statusnotifier = require("wibox.widget.systray.statusnotifier")

-- Record the warnings. The expected ones are not printed, since any warning
-- in the log fails the test (`tests/run.sh -W`). The others still are.
local warnings = {}
local print_warning = gdebug.print_warning

local expected_warnings = {
    -- The bogus item registered on purpose.
    "^statusnotifier: Cannot read the properties of [^ ]*/NoSuchItem, " ..
        "ignoring the item$",
}

function gdebug.print_warning(message)
    table.insert(warnings, message)

    for _, pattern in ipairs(expected_warnings) do
        if tostring(message):match(pattern) then return end
    end

    print_warning(message)
end

local function count_warnings(pattern)
    local n = 0
    for _, msg in ipairs(warnings) do
        if msg:find(pattern, 1, true) then n = n + 1 end
    end
    return n
end

-- The fake application -------------------------------------------------------

local function arg(name, signature)
    return Gio.DBusArgInfo { name = name, signature = signature }
end

local readable = Gio.DBusPropertyInfoFlags.READABLE

local item_info = Gio.DBusInterfaceInfo {
    name = "org.kde.StatusNotifierItem",
    methods = {
        Gio.DBusMethodInfo { name = "Activate",
            in_args = { arg("x", "i"), arg("y", "i") } },
        Gio.DBusMethodInfo { name = "SecondaryActivate",
            in_args = { arg("x", "i"), arg("y", "i") } },
        Gio.DBusMethodInfo { name = "Scroll",
            in_args = { arg("delta", "i"), arg("orientation", "s") } },
        Gio.DBusMethodInfo { name = "ContextMenu",
            in_args = { arg("x", "i"), arg("y", "i") } },
    },
    signals = {
        Gio.DBusSignalInfo { name = "NewTitle" },
        Gio.DBusSignalInfo { name = "NewStatus", args = { arg("status", "s") } },
    },
    properties = {
        Gio.DBusPropertyInfo { name = "Id", signature = "s", flags = readable },
        Gio.DBusPropertyInfo { name = "Title", signature = "s", flags = readable },
        Gio.DBusPropertyInfo { name = "Status", signature = "s", flags = readable },
        Gio.DBusPropertyInfo { name = "Category", signature = "s", flags = readable },
        Gio.DBusPropertyInfo { name = "IconName", signature = "s", flags = readable },
        Gio.DBusPropertyInfo { name = "IconPixmap", signature = "a(iiay)", flags = readable },
        Gio.DBusPropertyInfo { name = "ToolTip", signature = "(sa(iiay)ss)", flags = readable },
        Gio.DBusPropertyInfo { name = "Menu", signature = "o", flags = readable },
        Gio.DBusPropertyInfo { name = "ItemIsMenu", signature = "b", flags = readable },
    },
}

local app = {
    title       = "Fake app",
    status      = "Active",
    calls       = {},
}

-- A 2x1 pixmap: an opaque red pixel and a half transparent white one. The
-- data contains NUL bytes on purpose.
local pixmap_text = "[(2, 1, [byte 0xff, 0xff, 0x00, 0x00, 0x80, 0xff, 0xff, 0xff])]"

local function item_property(name)
    if name == "Id" then return GLib.Variant("s", "fake-app")
    elseif name == "Title" then return GLib.Variant("s", app.title)
    elseif name == "Status" then return GLib.Variant("s", app.status)
    elseif name == "Category" then return GLib.Variant("s", "ApplicationStatus")
    elseif name == "IconName" then return GLib.Variant("s", "")
    elseif name == "IconPixmap" then
        return GLib.Variant.parse(GLib.VariantType("a(iiay)"), pixmap_text, nil, nil)
    elseif name == "ToolTip" then
        return GLib.Variant("(sa(iiay)ss)", { "", {}, "Tip title", "Some <b>text</b><br/>here" })
    elseif name == "Menu" then return GLib.Variant("o", "/MenuBar")
    elseif name == "ItemIsMenu" then return GLib.Variant("b", false)
    end
end

local app_conn

local function start_app()
    local address = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION)

    app_conn = Gio.DBusConnection.new_for_address_sync(address,
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT +
        Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, nil, nil)

    assert(app_conn, "could not create the application connection")

    app_conn:register_object("/StatusNotifierItem", item_info,
        GObject.Closure(function(_, _, _, _, method, params, invocation)
            table.insert(app.calls, { method = method, params = params.value })
            invocation:return_value(GLib.Variant("()"))
        end),
        GObject.Closure(function(_, _, _, _, name)
            return item_property(name)
        end),
        nil)
end

local function register_app(path)
    app_conn:call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
        GLib.Variant("(s)", { path or "/StatusNotifierItem" }), nil,
        Gio.DBusCallFlags.NONE, -1, nil, function(c, res)
            local _, err = c:call_finish(res)
            assert(not err, tostring(err))
        end)
end

-- A second application, registered using a well-known name instead of an
-- object path (like KDE applications do).
local named = { title = "Named app" }

-- Export a minimal item at `path` on a new connection.
local function new_item_connection(path)
    local address = Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION)

    local conn = Gio.DBusConnection.new_for_address_sync(address,
        Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT +
        Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, nil, nil)

    conn:register_object(path, item_info,
        GObject.Closure(function(_, _, _, _, _, _, invocation)
            invocation:return_value(GLib.Variant("()"))
        end),
        GObject.Closure(function(_, _, _, _, name)
            if name == "Id" then return GLib.Variant("s", "named-app") end
            if name == "Title" then
                return GLib.Variant("s", named.title or "")
            end
            if name == "Menu" then return GLib.Variant("o", "/") end
            if name == "IconPixmap" then return GLib.Variant("a(iiay)", {}) end
            if name == "ToolTip" then
                return GLib.Variant("(sa(iiay)ss)", { "", {}, "", "" })
            end
            if name == "ItemIsMenu" then return GLib.Variant("b", false) end
            return GLib.Variant("s", "")
        end),
        nil)

    return conn
end

local function own_name(conn, name)
    local ret = conn:call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "RequestName",
        GLib.Variant("(su)", { name, 0 }), nil, Gio.DBusCallFlags.NONE, -1)
    assert(ret and ret.value[1] == 1, "could not own the name")
end

local function start_named_app()
    named.conn = new_item_connection("/StatusNotifierItem")
    named.name = "org.kde.StatusNotifierItem-4242-1"
    own_name(named.conn, named.name)

    named.conn:call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
        GLib.Variant("(s)", { named.name }), nil,
        Gio.DBusCallFlags.NONE, -1, nil, function(c, res)
            local _, err = c:call_finish(res)
            assert(not err, tostring(err))
        end)
end

-- Call `callback` with the value of a watcher property, as a GLib.Variant.
local function watcher_property(name, callback)
    app_conn:call("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
        "org.freedesktop.DBus.Properties", "Get",
        GLib.Variant("(ss)", { "org.kde.StatusNotifierWatcher", name }), nil,
        Gio.DBusCallFlags.NONE, -1, nil, function(c, res)
            local ret = c:call_finish(res)
            callback(ret and ret:get_child_value(0):get_variant())
        end)
end

-- Convert an array variant to a table. Arrays are not unpacked by `.value`.
local function array_to_table(v)
    local ret = {}
    for i = 0, v:n_children() - 1 do
        table.insert(ret, v:get_child_value(i).value)
    end
    return ret
end

-- The test ---------------------------------------------------------------------

-- Nothing starts the StatusNotifierItem support yet.
statusnotifier.start()

local added, removed, updated, item = 0, 0, 0, nil

statusnotifier:connect_signal("item::added", function(_, i)
    added = added + 1
    item = i
end)

statusnotifier:connect_signal("item::removed", function(_, i)
    if i == item then
        removed = removed + 1
    end
end)

statusnotifier:connect_signal("item::updated", function(_, i)
    if i == item then
        updated = updated + 1
    end
end)

local host_registered, bogus_registered_at, bogus_warned_at

-- Is `name` owned on the session bus?
local function has_owner(name)
    local conn = Gio.bus_get_sync(Gio.BusType.SESSION)
    local ret = conn:call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "NameHasOwner",
        GLib.Variant("(s)", { name }), nil,
        Gio.DBusCallFlags.NONE, -1)
    return ret and ret.value[1]
end

-- The StatusNotifierWatcher and StatusNotifierHost names on the bus.
local function sni_names()
    local conn = Gio.bus_get_sync(Gio.BusType.SESSION)
    local ret = conn:call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus", "ListNames", nil, nil,
        Gio.DBusCallFlags.NONE, -1)
    local names = {}
    for _, name in ipairs(array_to_table(ret:get_child_value(0))) do
        if name:find("%.StatusNotifier[WH]") then
            table.insert(names, name)
        end
    end
    return names
end

-- The number of functions connected to a statusnotifier signal.
local function count_handlers(name)
    local n = 0
    for _ in pairs(statusnotifier._signals[name].strong) do n = n + 1 end
    return n
end

local disabled = {}

local steps = {
    -- Wait for our watcher to be up, then start the application.
    function()
        local done = false
        local conn = Gio.bus_get_sync(Gio.BusType.SESSION)
        local owner = conn:call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "NameHasOwner",
            GLib.Variant("(s)", { "org.kde.StatusNotifierWatcher" }), nil,
            Gio.DBusCallFlags.NONE, -1)

        if owner and owner.value[1] then
            start_app()
            register_app()
            done = true
        end

        return done or nil
    end,

    -- The item shows up.
    function()
        if added == 0 then return end

        assert(added == 1)
        assert(#statusnotifier.get_items() == 1)
        assert(item.id == "fake-app", tostring(item.id))
        assert(item.title == "Fake app")
        assert(item.status == "Active")
        assert(item.menu_path == "/MenuBar")
        assert(item.item_is_menu == false)
        assert(item.path == "/StatusNotifierItem")
        assert(item.service:sub(1, 1) == ":")
        assert(item.tooltip.title == "Tip title")

        -- The pixmap is kept as received.
        local pixmap = item._private.raw.IconPixmap
        assert(pixmap and pixmap:n_children() == 1)

        watcher_property("IsStatusNotifierHostRegistered", function(v)
            host_registered = v and v.value
        end)

        return true
    end,

    -- The watcher sees the host.
    function()
        if host_registered == nil then return end
        assert(host_registered == true)
        return true
    end,

    -- An item whose object does not exist is never displayed. The initial
    -- load is retried a few times, then a single warning is emitted.
    function(count)
        if count == 1 then
            bogus_registered_at = GLib.get_monotonic_time()
            register_app("/NoSuchItem")
        end

        local n = count_warnings("/NoSuchItem")

        if n == 0 then
            assert(#statusnotifier.get_items() == 1)
            return
        end

        if not bogus_warned_at then
            -- The load was retried (about one second apart) before giving up.
            local elapsed = (GLib.get_monotonic_time() - bogus_registered_at) / 1e6
            print(string.format("Bogus item ignored after %.2fs", elapsed))
            assert(elapsed > 1.5, elapsed)
            bogus_warned_at = count
        end

        -- Wait a bit more to check that nothing else happens.
        if count < bogus_warned_at + 15 then return end

        assert(n == 1, n)
        assert(added == 1, added)
        assert(#statusnotifier.get_items() == 1)
        assert(statusnotifier.get_items()[1] == item)

        return true
    end,

    -- Method calls are forwarded.
    function(count)
        if count == 1 then
            item:activate(10, 10)
            item:secondary_activate(10, 10)
            item:scroll(-1, "vertical")
            item:context_menu(10, 10)
        end

        if #app.calls < 4 then return end

        assert(app.calls[1].method == "Activate")
        assert(app.calls[1].params[1] == 10 and app.calls[1].params[2] == 10)
        assert(app.calls[2].method == "SecondaryActivate")
        assert(app.calls[3].method == "Scroll")
        assert(app.calls[3].params[1] == -1)
        assert(app.calls[3].params[2] == "vertical")
        assert(app.calls[4].method == "ContextMenu")
        assert(app.calls[4].params[1] == 10 and app.calls[4].params[2] == 10)

        return true
    end,

    -- Property updates are followed.
    function(count)
        if count == 1 then
            updated = 0
            app.title = "New title"
            app_conn:emit_signal(nil, "/StatusNotifierItem",
                "org.kde.StatusNotifierItem", "NewTitle", nil)
        end

        if item.title ~= "New title" then return end

        assert(updated == 1, updated)

        return true
    end,

    -- Status updates are followed.
    function(count)
        if count == 1 then
            app.status = "Passive"
            app_conn:emit_signal(nil, "/StatusNotifierItem",
                "org.kde.StatusNotifierItem", "NewStatus",
                GLib.Variant("(s)", { "Passive" }))
        end

        if item.status ~= "Passive" then return end

        assert(#statusnotifier.get_items() == 1)

        return true
    end,

    -- Stopping the StatusNotifierItem support removes the items and releases
    -- everything on the bus.
    function(count)
        if count == 1 then
            disabled.item = item
            disabled.added = added
            disabled.handlers = count_handlers("item::added")
            assert(#sni_names() == 4, #sni_names())
            statusnotifier.stop()

            -- The items are removed synchronously.
            assert(removed == 1, removed)
            assert(#statusnotifier.get_items() == 0)
            assert(item._private.removed)
            assert(not item._private.subscription)
        end

        if has_owner("org.kde.StatusNotifierWatcher") then return end
        if #sni_names() > 0 then return end

        return true
    end,

    -- Nothing comes back while disabled.
    function(count)
        if count < 5 then return end

        assert(#sni_names() == 0)
        assert(#statusnotifier.get_items() == 0)
        assert(added == disabled.added)

        return true
    end,

    -- Starting it again starts everything again. Like real applications, the
    -- fake application registers again once the new watcher is up.
    function(count)
        if count == 1 then
            statusnotifier.start()
        end

        if not disabled.registered_again then
            if not has_owner("org.kde.StatusNotifierWatcher") then return end
            register_app()
            disabled.registered_again = true
        end

        if added == disabled.added then return end

        assert(added == disabled.added + 1)
        assert(item ~= disabled.item)
        assert(item.service == disabled.item.service)
        assert(item.path == "/StatusNotifierItem")
        assert(item.title == "New title")
        assert(#statusnotifier.get_items() == 1)

        -- The signals are not connected twice.
        assert(count_handlers("item::added") == disabled.handlers)

        return true
    end,

    -- Registering again does not duplicate the item.
    function(count)
        if count == 1 then
            register_app()
        end

        if count < 5 then return end

        assert(added == disabled.added + 1, added)
        assert(#statusnotifier.get_items() == 1)

        return true
    end,

    -- The watcher sees the host again, and nothing is duplicated.
    function(count)
        if count == 1 then
            host_registered, disabled.watcher_items = nil, nil
            watcher_property("IsStatusNotifierHostRegistered", function(v)
                host_registered = v and v.value
            end)
            watcher_property("RegisteredStatusNotifierItems", function(v)
                disabled.watcher_items = v and array_to_table(v)
            end)
        end

        if host_registered == nil or not disabled.watcher_items then return end
        if count < 5 then return end

        assert(host_registered == true)

        -- The item is registered once.
        local items = disabled.watcher_items
        assert(#items == 1, #items)
        assert(items[1] == item.service .. "/StatusNotifierItem", items[1])

        assert(#sni_names() == 4, #sni_names())
        assert(#statusnotifier.get_items() == 1)
        assert(added == disabled.added + 1)

        -- For the next step.
        removed = 0

        return true
    end,

    -- The item goes away with the application.
    function(count)
        if count == 1 then
            app_conn:close_sync(nil)
        end

        if removed == 0 then return end

        assert(#statusnotifier.get_items() == 0)

        return true
    end,

    -- An item registered with a well-known name.
    function(count)
        if count == 1 then
            start_named_app()
        end

        named.item = statusnotifier.get_items()[1]

        if not named.item then return end

        assert(named.item.service == named.name, named.item.service)
        assert(named.item.title == "Named app")

        return true
    end,

    -- Signals are received even though they come from the unique name.
    function(count)
        if count == 1 then
            named.title = "Renamed"
            named.conn:emit_signal(nil, "/StatusNotifierItem",
                "org.kde.StatusNotifierItem", "NewTitle", nil)
        end

        if named.item.title ~= "Renamed" then return end

        return true
    end,

    -- Releasing the name removes the item.
    function(count)
        if count == 1 then
            named.conn:close_sync(nil)
        end

        if #statusnotifier.get_items() > 0 then return end

        return true
    end,
}

-- Leave enough time for the initial load retries of the bogus item.
runner.run_steps(steps, { wait_per_step = 5 })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
