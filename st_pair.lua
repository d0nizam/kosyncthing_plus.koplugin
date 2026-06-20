-- st_pair.lua — Device pairing: guided wizard and pending-request acceptance
--
-- Wizard (startPairWizard):
--   1. Show this device's ID + QR code with clear instructions.
--   2. Poll the API for incoming pending-device requests every few seconds.
--   3. When one arrives, show a confirmation dialog and accept it on the
--      user's say-so.
--
-- Pending-request acceptance (called from st_menu getStatusMenu):
--   acceptDevice — add a pending device + offer to share all existing folders
--   acceptFolder — path confirmation dialog + automatic FAT/FUSE safe defaults

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local QRMessage   = require("ui/widget/qrmessage")
local UIManager   = require("ui/uimanager")
local FS          = require("st_filesystem")
local time 		  = require("ui/time")
local JSON        = require("json")
local util 		  = require("util")
local _           = require("syncthing_i18n").gettext
local N_          = require("syncthing_i18n").ngettext
local T           = require("ffi/util").template
local Device      = require("device")

local U = require("st_utils")

-- Polling schedule.  Starts fast (so a quickly-arriving request gets a
-- response within a few seconds) but backs off exponentially up to a
-- ceiling, so a long-running wizard doesn't spam the API or pile up
-- _last_api_error toasts if the daemon is misbehaving.
--
-- Schedule: 4s, 8s, 16s, 30s, 30s, 30s, ... (capped at 30s).
-- That gives 8 poll attempts in the first ~2 minutes (when the user is
-- actively waiting) and roughly 1 every 30s after that.
local POLL_FIRST_INTERVAL_SEC = 4
local POLL_MAX_INTERVAL_SEC   = 30
local POLL_TIMEOUT_SEC        = 300   -- give up after 5 minutes
local _confirm_active 		  = false

local function _nextPollDelay(current)
    if not current or current < POLL_FIRST_INTERVAL_SEC then
        return POLL_FIRST_INTERVAL_SEC
    end
    local doubled = current * 2
    if doubled > POLL_MAX_INTERVAL_SEC then
        return POLL_MAX_INTERVAL_SEC
    end
    return doubled
end

-- Forward declaration so the polling function can call itself.
local _pollForPendingDevice

---------------------------------------------------------------------------
-- Show a single accept/ignore dialog for one pending device.
---------------------------------------------------------------------------
local function _confirmPendingDevice(self, device_id, device_info, qr_widget, on_done)
    local name = (device_info and device_info.name) or device_id
	
	_confirm_active = true

    UIManager:show(ConfirmBox:new{
        text = T(_(
            "Pairing request from:\n\n"
            .. "%1\n\n"
            .. "Device ID: %2\n\n"
            .. "Accept this device? Once accepted, you can share folders with it."),
            name, device_id),
        ok_text     = _("Accept"),
        cancel_text = _("Ignore"),
        ok_callback = function()
		_confirm_active = false
            local result = self:addDevice({
                deviceID = device_id,
                name     = name,
                _editing = "new-pending",
            })
            local ok = U.isOk(result)
            self:_invalidateProcess()

            if qr_widget then
                pcall(function() UIManager:close(qr_widget) end)
            end

            UIManager:show(InfoMessage:new{
                icon    = (not ok) and "notice-warning" or nil,
                timeout = 3,
                text    = ok
                    and T(_("Paired with \"%1\" successfully.\n\nUse the Web GUI on either device to share folders."), name)
                    or  T(_("Could not save the device.\n\n%1"), U.errOf(result)),
            })
            if on_done then on_done(ok) end
        end,
        cancel_callback = function()
		_confirm_active = false
            self:ignorePendingDevice(device_id)
            self:_invalidateProcess()
            if on_done then on_done(false) end
        end,
        -- ok_callback / cancel_callback are bypassed when the ConfirmBox is
        -- closed by external means: UIManager:close() from another code path,
        -- a power event, or the hardware back button on some KOReader builds.
        -- Without this handler _confirm_active would stay true for the rest of
        -- the session, permanently silencing the pairing heartbeat toasts
        -- (BUG-23).  dismiss_callback runs on every close, including the normal
        -- ok/cancel paths — resetting an already-false flag is harmless.
        dismiss_callback = function()
            _confirm_active = false
        end,
    })
end

---------------------------------------------------------------------------
-- Recursively poll the pending-devices endpoint.
---------------------------------------------------------------------------
_pollForPendingDevice = function(self, started_at, dialog_alive, qr_widget, current_delay)
    if not dialog_alive() then return end

    if (time.to_s(time.now()) - started_at) > POLL_TIMEOUT_SEC then
        if qr_widget then
            pcall(function() UIManager:close(qr_widget) end)
        end
        UIManager:show(InfoMessage:new{
            timeout = 4,
            text    = _("Stopped waiting for a pairing request.\n\n"
                     .. "If the other device shows a pending request later, you can accept it from “Pending devices & folders”."),
        })
        return
    end

    if not self:isRunning() then
        if qr_widget then
            pcall(function() UIManager:close(qr_widget) end)
        end
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Syncthing has stopped. Pairing wizard cancelled."),
        })
        return
    end

    self._suppress_api_errors = true
    local ok_call, pending_or_err = pcall(function()
        return self:getPendingDevices() or {}
    end)
    self._suppress_api_errors = false
    local pending = ok_call and pending_or_err or {}

	local pending_list = {}
	for id, info in pairs(pending) do
		table.insert(pending_list, { id = id, info = info })
	end

	if #pending_list > 0 then
		local function confirmNext(i)
			if i > #pending_list then
				UIManager:scheduleIn(POLL_FIRST_INTERVAL_SEC, function()
					_pollForPendingDevice(self, started_at, dialog_alive,
						qr_widget, POLL_FIRST_INTERVAL_SEC)
				end)
				return
			end
			local entry = pending_list[i]
			_confirmPendingDevice(self, entry.id, entry.info, qr_widget,
				function(_)
					confirmNext(i + 1)
				end)
		end
		confirmNext(1)
		return
	end

    local next_delay = _nextPollDelay(current_delay)

    UIManager:scheduleIn(next_delay, function()
        _pollForPendingDevice(
            self, started_at, dialog_alive, qr_widget, next_delay)
    end)
end

---------------------------------------------------------------------------
-- Public: start the pairing wizard.
---------------------------------------------------------------------------
local function startPairWizard(self)
    if not self:isRunning() then
        UIManager:show(InfoMessage:new{
            text = _("Start Syncthing first — pairing requires the daemon to be running."),
        })
		_confirm_active = false -- ensure heartbeat can run on next wizard
        return
    end

    local device_id = self:getDeviceId()
    if not device_id then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Could not read this device's Syncthing ID.\n\n"
                  .. "Try restarting Syncthing — the ID is generated on first run."),
        })
		_confirm_active = false
        return
    end

    local alive = true
    local function isAlive() return alive end

    local qr_widget

    UIManager:show(ConfirmBox:new{
        text = T(_(
            "Pairing wizard\n\n"
            .. "On the other device:\n"
            .. "  1. Open Syncthing\n"
            .. "  2. Add this device by ID or scan the QR code\n\n"
            .. "Your device ID:\n%1\n\n"
            .. "Once the other device sends a request, this wizard will offer to accept it automatically."),
            device_id),
        ok_text     = _("Show QR code"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            qr_widget = QRMessage:new{
                text   = device_id,
                width  = math.floor(Device.screen:getWidth() * 0.8),
                height = math.floor(Device.screen:getHeight() * 0.8),
                dismiss_callback = function()
                    alive = false
					_confirm_active = false
                    -- Show the device ID as plain text after the QR is dismissed.
                    UIManager:show(InfoMessage:new{
                        text = T(_("Pairing wizard closed.\n\nYour device ID:\n%1\n\n"
                               .. "The other device needs this ID to add you."),
                               device_id),
                    })
                end,
            }
            UIManager:show(qr_widget)

            UIManager:scheduleIn(0.5, function()
                if not alive then return end
                UIManager:show(InfoMessage:new{
                    timeout = 6,
                    text = _("The wizard is now waiting for the other device to send a pairing request.\n\n"
                          .. "It will keep watching for up to 5 minutes. Close the QR code when done."),
                })
            end)

			local pair_started_at = time.to_s(time.now())

			-- recursive self-scheduling
			local function _pairHeartbeat()
				if not alive or _confirm_active then return end
				if not self:isRunning() then return end   -- daemon stopped: stop showing progress
				local remaining = POLL_TIMEOUT_SEC - (time.to_s(time.now()) - pair_started_at)
				if remaining <= 0 then return end
				UIManager:show(InfoMessage:new{
					timeout = 3,
					text    = T(_("Still watching for pairing request — %1 min remaining."),
								math.ceil(remaining / 60)),
				})
				UIManager:scheduleIn(60, _pairHeartbeat)
			end
			UIManager:scheduleIn(60, _pairHeartbeat)

			UIManager:scheduleIn(POLL_FIRST_INTERVAL_SEC, function()
				_pollForPendingDevice(
					self, pair_started_at, isAlive, qr_widget,
					POLL_FIRST_INTERVAL_SEC)
			end)
        end,
        cancel_callback = function()
			alive = false
			_confirm_active = false
        end,
    })
end

---------------------------------------------------------------------------
-- Accept a pending device pairing request
--
-- Called from the Status menu when the user taps a pending device row.
-- Adds the device to Syncthing config and optionally shares all existing
-- configured folders with it — the most common next step after pairing.
---------------------------------------------------------------------------
local function acceptDevice(self, device_id, device_name, touchmenu_instance)
    local result = self:addDevice({
        deviceID = device_id,
        name     = device_name,
        _editing = "new-pending",
    })
    local ok = U.isOk(result)
    if not ok then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Could not add device.\n\n%1"), U.errOf(result)),
        })
        return
    end
    self:_invalidateProcess()
    if touchmenu_instance then touchmenu_instance:updateItems() end

    -- Offer to add the new device to all existing configured folders.
    -- This saves the user from having to do it manually in the Web GUI,
    -- and is the most common thing you want after pairing a new device.
    local cfg_folders = self:getFolders() or {}
    local folder_count = 0
    for _ in pairs(cfg_folders) do folder_count = folder_count + 1 end

    if folder_count > 0 then
        UIManager:show(ConfirmBox:new{
            text = T(_(
                "Device '%1' added.\n\n"
                .. "Share all %2 of your configured folder(s) with this device?\n\n"
                .. "(You can always adjust folder sharing later via Syncthing's Web GUI.)"),
                device_name, folder_count),
            ok_text     = _("Share all folders"),
            cancel_text = _("Skip"),
            ok_callback = function()
                local added, failed = 0, 0
                for _, folder in pairs(cfg_folders) do
                    local fid = folder["id"]
                    if fid and fid ~= "" then
                        -- Check the device isn't already in this folder
                        local devices = folder["devices"] or {}
                        local already = false
                        for _, d in pairs(devices) do
                            if d["deviceID"] == device_id then already = true; break end
                        end
                        if not already then
                            -- Clone the device list and PATCH only devices field
                            local new_devices = {}
                            for _, d in pairs(devices) do
                                table.insert(new_devices, d)
                            end
                            table.insert(new_devices, { deviceID = device_id, introducedBy = "" })
                            -- PATCH only the devices field to avoid overwriting stale folder config
                            local r = self:patchFolder(fid, { devices = new_devices })
                            if U.isOk(r) then added = added + 1 else failed = failed + 1 end
                        else
                            added = added + 1  -- already there, counts as OK
                        end
                    end
                end
                self:_invalidateFolders()
                if touchmenu_instance then touchmenu_instance:updateItems() end
                if failed > 0 then
                    UIManager:show(InfoMessage:new{
                        icon = "notice-warning",
                        text = T(N_("%1 added to %2 folder.", "%1 added to %2 folders.", added), device_name, added)
                            .. " " ..
                            T(N_("%1 folder could not be updated.", "%1 folders could not be updated.", failed), failed),
                    })
                else
                    UIManager:show(InfoMessage:new{
                        timeout = 3,
                        text = T(N_("%1 added and shared with %2 folder.", "%1 added and shared with all %2 folders.", added), device_name, added),
                    })
                end
            end,
            cancel_callback = function()
                UIManager:show(InfoMessage:new{
                    timeout = 2,
                    text = T(_("Device %1 added. No folders were shared."), device_name),
                })
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            timeout = 2,
            text = T(_("Device %1 added."), device_name),
        })
    end
end

---------------------------------------------------------------------------
-- Accept a pending folder share offer
--
-- Called from the Status menu when the user taps a pending folder row.
-- Prompts the user to confirm or adjust the destination path, detects
-- FAT/FUSE filesystems to set safe defaults, then adds the folder.
---------------------------------------------------------------------------
local function acceptFolder(self, folder_id, label, offerer, touchmenu_instance)
    local home = G_reader_settings:readSetting("home_dir") or ""
    home = home:match("^(.-)/*$")
    if home == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _(
                "Cannot accept folder.\n\n"
                .. "Your KOReader home directory is not set.\n"
                .. "Please go to KOReader Settings → Home folder and set a safe path first."),
        })
        return
    end

    local my_id = self:getDeviceId() or ""
    local folder_leaf = FS.sanitiseName(label or folder_id)
    if not folder_leaf then
        folder_leaf = folder_id
    end
    local default_path = home .. "/" .. folder_leaf

    -- Let the user confirm or adjust the destination path before accepting.
    local dlg
    dlg = InputDialog:new{
        title       = T(_("Accept folder \"%1\""), label or folder_id),
        description = _("Syncthing will sync files to this path on your device.\nChange it if you want the folder somewhere else."),
        input       = default_path,
        input_type  = "string",
        buttons     = {{
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Accept"),
                is_enter_default = true,
                callback         = function()
                    local chosen_path = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
                    if chosen_path == "" then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = _("Path cannot be empty."),
                        })
                        return
                    end

                    local has_parent_ref = chosen_path == ".."
                        or chosen_path:match("^%.%./")
                        or chosen_path:match("/%.%./")
                        or chosen_path:match("/%.%.$")
                    if has_parent_ref or chosen_path == "/" or U.DANGEROUS_PATHS[chosen_path] then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = _("Cannot use this path — it is a system directory."),
                        })
                        return
                    end
                    UIManager:close(dlg)

                    if not U.isValidDeviceID(my_id) or not U.isValidDeviceID(offerer) then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = _(
                                "Cannot accept folder.\n\n"
                                .. "The pending folder did not include a valid offering device ID."),
                        })
                        return
                    end

                    local device_list = {
                        { deviceID = my_id,   introducedBy = "" },
                        { deviceID = offerer, introducedBy = "" },
                    }

                    local chosen_fs_type = util.getFilesystemType(chosen_path)
                    if not chosen_fs_type then
                        local parent = chosen_path:match("^(/[^/]+)")
                        if parent then chosen_fs_type = util.getFilesystemType(parent) end
                    end
                    local is_fat_like = chosen_fs_type and (
                        chosen_fs_type == "vfat" or chosen_fs_type == "msdos"
                        or chosen_fs_type:match("^fuse%.") ~= nil)

                    local result = self:addFolder({
                        id             = folder_id,
                        label          = label or folder_id,
                        path           = chosen_path,
                        filesystemType = "basic",
                        type           = "sendreceive",
                        devices        = device_list,
                        _editing       = "new-pending",
                        modTimeWindowS = is_fat_like and 2 or 0,
                        ignorePerms    = is_fat_like and true or false,
                        syncOwnership  = is_fat_like and false or nil,
                        sendOwnership  = is_fat_like and false or nil,
                        syncXattrs     = false,
                        sendXattrs     = false,
                    })
                    local ok = U.isOk(result)
                    if not ok then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = T(_("Could not add folder.\n\n%1"), U.errOf(result)),
                        })
                        return
                    end
                    self:_invalidateFolders()
                    if touchmenu_instance then touchmenu_instance:updateItems() end

                    UIManager:show(InfoMessage:new{
                        timeout = 3,
                        text    = T(_(
                            "Folder \"%1\" added to \"%2\" and shared with the offering device."),
                            label or folder_id, chosen_path),
                    })
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return {
    startPairWizard = startPairWizard,
    acceptDevice    = acceptDevice,
    acceptFolder    = acceptFolder,
}