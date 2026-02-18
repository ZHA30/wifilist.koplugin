--[[--
Wi-Fi list plugin.
Keeps current menu style and reuses KOReader native Wi-Fi widgets.
--]]--

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local NetworkSetting = require("ui/widget/networksetting")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local filemanager_order = require("ui/elements/filemanager_menu_order")
local reader_order = require("ui/elements/reader_menu_order")
local _ = require("gettext")
local GetText = require("gettext")

local WifiList = WidgetContainer:extend{
    name = "wifilist",
    is_doc_only = false,
}

local MENU_ID = "network_wifi_list"
local KINDLE_APP_ID = "com.github.koreader.wifilist"
local KINDLE_WIFI_SERVICE = "com.lab126.wifid"
local PLUGIN_L10N_FILE = "koreader.mo"
local LOADED_FLAG = "__wifilist_i18n_loaded"
local PLUGIN_ROOT = (debug.getinfo(1, "S").source or ""):match("@?(.*/)")

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function currentLocale()
    local locale = G_reader_settings and G_reader_settings:readSetting("language") or _.current_lang
    locale = tostring(locale or "")
    locale = locale:match("^([^:]+)") or locale
    locale = locale:gsub("%..*$", "")
    return locale
end

local function loadPluginTranslations()
    if _G[LOADED_FLAG] then
        return
    end

    if not PLUGIN_ROOT then
        return
    end

    local locale = currentLocale()
    if not isNonEmptyString(locale) or locale == "C" then
        return
    end

    _G[LOADED_FLAG] = true

    local function tryLoad(lang)
        if not isNonEmptyString(lang) then
            return false
        end
        local mo_path = string.format("%sl10n/%s/%s", PLUGIN_ROOT, lang, PLUGIN_L10N_FILE)
        local ok, loaded = pcall(function()
            return GetText.loadMO(mo_path)
        end)
        return ok and loaded == true
    end

    if tryLoad(locale) then
        return
    end

    local lang_only = locale:match("^([A-Za-z][A-Za-z])[_%-]")
    if lang_only and tryLoad(lang_only) then
        return
    end

    if locale:lower():match("^zh") then
        tryLoad("zh_CN")
    end
end

local function showMessage(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

local function insertAfter(list, anchor_id, item_id)
    if type(list) ~= "table" then
        return
    end
    for _, value in ipairs(list) do
        if value == item_id then
            return
        end
    end
    for idx, value in ipairs(list) do
        if value == anchor_id then
            table.insert(list, idx + 1, item_id)
            return
        end
    end
    table.insert(list, item_id)
end

local function getConnectedSSID()
    local ok, current = pcall(function()
        return NetworkMgr:getCurrentNetwork()
    end)
    if ok and type(current) == "table" and isNonEmptyString(current.ssid) then
        return current.ssid
    end
    return nil
end

local function normalizeNetworkList(network_list)
    if type(network_list) ~= "table" then
        return {}
    end

    for _, network in ipairs(network_list) do
        if type(network.flags) ~= "string" then
            network.flags = ""
        end
        if type(network.signal_quality) ~= "number" then
            network.signal_quality = -1
        end
    end

    table.sort(network_list, function(left, right)
        return (left.signal_quality or -math.huge) > (right.signal_quality or -math.huge)
    end)
    return network_list
end

local function withKindleLipcClient(callback)
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if not ok_lipc then
        return false
    end
    local lipc_handle = lipc.init(KINDLE_APP_ID)
    if not lipc_handle then
        return false
    end

    local ok = pcall(callback, lipc_handle)
    lipc_handle:close()
    return ok
end

local function kindleSetIntProperty(property_name, value)
    return withKindleLipcClient(function(lipc_handle)
        lipc_handle:set_int_property(KINDLE_WIFI_SERVICE, property_name, value)
    end)
end

local function kindleSetStringProperty(property_name, value)
    return withKindleLipcClient(function(lipc_handle)
        lipc_handle:set_string_property(KINDLE_WIFI_SERVICE, property_name, value or "")
    end)
end

local function enableKindleWifiRadioOnly()
    if kindleSetIntProperty("enable", 1) then
        return true
    end
    local status = os.execute("lipc-set-prop -i com.lab126.wifid enable 1 >/dev/null 2>&1")
    return status == true or status == 0
end

local function kindleDeleteProfile(setting)
    if type(setting) ~= "table" or not isNonEmptyString(setting.ssid) then
        return false
    end

    local ok_lipc, lipc = pcall(require, "libopenlipclua")
    if ok_lipc then
        local lipc_handle = lipc.open_no_name()
        if lipc_handle then
            local profile = lipc_handle:new_hasharray()
            profile:add_hash()
            profile:put_string(0, "essid", setting.ssid)
            if type(setting.netid) == "number" then
                profile:put_int(0, "netid", setting.netid)
            end
            local ok, result = pcall(function()
                return lipc_handle:access_hash_property(KINDLE_WIFI_SERVICE, "deleteProfile", profile)
            end)
            if ok and result then
                result:destroy()
            end
            profile:destroy()
            lipc_handle:close()
            if ok then
                return true
            end
        end
    end

    return kindleSetStringProperty("deleteProfile", setting.ssid)
end

local function getKindleCurrentSSID(lipc_handle)
    local ha_input = lipc_handle:new_hasharray()
    local ok_profile, ha_result = pcall(function()
        return lipc_handle:access_hash_property(KINDLE_WIFI_SERVICE, "currentEssid", ha_input)
    end)

    local current_ssid = nil
    if ok_profile and ha_result then
        local profile = ha_result:to_table()
        if type(profile) == "table" and type(profile[1]) == "table" and isNonEmptyString(profile[1].essid) then
            current_ssid = profile[1].essid
        end
        ha_result:destroy()
    end
    ha_input:destroy()
    return current_ssid
end

local function getKindleSavedProfiles(lipc_handle)
    local saved_by_netid = {}
    local saved_by_ssid = {}

    local ha_input = lipc_handle:new_hasharray()
    local ok_profiles, ha_result = pcall(function()
        return lipc_handle:access_hash_property(KINDLE_WIFI_SERVICE, "profileData", ha_input)
    end)
    if ok_profiles and ha_result then
        local profiles = ha_result:to_table()
        if type(profiles) == "table" then
            for _, profile in ipairs(profiles) do
                if type(profile) == "table" then
                    if type(profile.netid) == "number" then
                        saved_by_netid[profile.netid] = profile
                    end
                    if isNonEmptyString(profile.essid) and saved_by_ssid[profile.essid] == nil then
                        saved_by_ssid[profile.essid] = profile
                    end
                end
            end
        end
        ha_result:destroy()
    end
    ha_input:destroy()

    return saved_by_netid, saved_by_ssid
end

local function kindleScanList()
    local ok_lipc, lipc = pcall(require, "libopenlipclua")
    if not ok_lipc then
        return nil
    end
    local lipc_handle = lipc.open_no_name()
    if not lipc_handle then
        return nil
    end

    local current_ssid = getKindleCurrentSSID(lipc_handle)
    local saved_by_netid, saved_by_ssid = getKindleSavedProfiles(lipc_handle)

    local ha_input = lipc_handle:new_hasharray()
    local ok_scan, ha_results = pcall(function()
        return lipc_handle:access_hash_property(KINDLE_WIFI_SERVICE, "scanList", ha_input)
    end)
    if not ok_scan or not ha_results then
        ha_input:destroy()
        lipc_handle:close()
        return nil
    end

    local raw_list = ha_results:to_table()
    ha_results:destroy()
    ha_input:destroy()
    lipc_handle:close()
    if type(raw_list) ~= "table" then
        return nil
    end

    local qualities = {
        [1] = 0,
        [2] = 6,
        [3] = 31,
        [4] = 56,
        [5] = 81,
    }

    local list = {}
    for _, nw in ipairs(raw_list) do
        local ssid = nw.essid
        if isNonEmptyString(ssid) then
            local password
            if nw.known == "yes" then
                local saved_profile = type(nw.netid) == "number" and saved_by_netid[nw.netid] or nil
                if saved_profile == nil then
                    saved_profile = saved_by_ssid[ssid]
                end
                if saved_profile ~= nil then
                    if type(saved_profile.psk) == "string" then
                        password = saved_profile.psk
                    else
                        password = ""
                    end
                end
            end
            table.insert(list, {
                ssid = ssid,
                flags = nw.key_mgmt or "",
                signal_level = string.format("%s/%s", tostring(nw.signal or "?"), tostring(nw.signal_max or "?")),
                signal_quality = qualities[nw.signal] or -1,
                connected = current_ssid ~= nil and ssid == current_ssid,
                password = password,
            })
        end
    end
    return list
end

function WifiList:ensureMenuOrder()
    insertAfter(reader_order.network, "network_wifi", MENU_ID)
    insertAfter(filemanager_order.network, "network_wifi", MENU_ID)
end

function WifiList:installKindleDeleteCompat()
    if self._kindle_delete_compat_installed or not Device:isKindle() or type(NetworkMgr.deleteNetwork) ~= "function" then
        return
    end

    local original_delete_network = NetworkMgr.deleteNetwork
    NetworkMgr.deleteNetwork = function(network_mgr, setting)
        pcall(original_delete_network, network_mgr, setting)
        kindleDeleteProfile(setting)
    end

    self._kindle_delete_compat_installed = true
end

function WifiList:scanAndShowWifiList()
    local scanning = InfoMessage:new{
        text = _("Scanning for networks..."),
    }
    UIManager:show(scanning)
    UIManager:forceRePaint()

    local network_list, err = NetworkMgr:getNetworkList()
    if type(network_list) == "table" and #network_list == 0 then
        network_list, err = NetworkMgr:getNetworkList()
    end
    UIManager:close(scanning)

    if network_list == nil then
        showMessage(err or _("Failed to scan Wi-Fi networks."), 3)
        return
    end

    if Device:isKindle() and #network_list == 1 and network_list[1].connected then
        local scanned = kindleScanList()
        if type(scanned) == "table" and #scanned > 0 then
            network_list = scanned
        end
    end

    network_list = normalizeNetworkList(network_list)
    if #network_list == 0 then
        showMessage(_("No Wi-Fi networks found."), 3)
        return
    end

    UIManager:show(NetworkSetting:new{
        network_list = network_list,
    })
end

function WifiList:waitAndShowWifiList()
    local max_iter = 80
    local function check(iter)
        NetworkMgr:queryNetworkState()
        if NetworkMgr:isWifiOn() then
            self:scanAndShowWifiList()
            return
        end
        if iter >= max_iter then
            showMessage(_("Failed to enable Wi-Fi."), 3)
            return
        end
        UIManager:scheduleIn(0.25, check, iter + 1)
    end
    UIManager:scheduleIn(0.25, check, 1)
end

function WifiList:openWifiList()
    if not (Device.hasWifiToggle and Device:hasWifiToggle()) then
        showMessage(
            _("This device does not support Wi-Fi toggling in KOReader."),
            3
        )
        return
    end

    if Device.isAndroid and Device:isAndroid() then
        if NetworkMgr.openSettings then
            NetworkMgr:openSettings()
            return
        end
        showMessage(_("Opened system Wi-Fi settings."), 2)
        return
    end

    NetworkMgr:queryNetworkState()
    if NetworkMgr:isWifiOn() then
        self:scanAndShowWifiList()
        return
    end

    if Device:isKindle() then
        if not enableKindleWifiRadioOnly() then
            showMessage(_("Failed to enable Wi-Fi."), 3)
            return
        end
        self:waitAndShowWifiList()
        return
    end

    local ok = pcall(function()
        NetworkMgr:toggleWifiOn(function()
            self:scanAndShowWifiList()
        end, nil, true)
    end)
    if not ok then
        showMessage(_("Failed to enable Wi-Fi."), 3)
    end
end

function WifiList:init()
    loadPluginTranslations()

    self:ensureMenuOrder()
    self:installKindleDeleteCompat()
    self.ui.menu:registerToMainMenu(self)
end

function WifiList:addToMainMenu(menu_items)
    menu_items[MENU_ID] = {
        text_func = function()
            local ssid = getConnectedSSID()
            if ssid then
                return string.format("%s: %s", _("Wi-Fi list"), ssid)
            end
            return _("Wi-Fi list")
        end,
        sorting_hint = "network",
        keep_menu_open = true,
        enabled_func = function()
            return Device:hasWifiToggle()
        end,
        callback = function()
            self:openWifiList()
        end,
    }
end

return WifiList
