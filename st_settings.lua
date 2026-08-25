-- st_settings.lua — GUI password management and first-run password prompt
--
-- Extracted from st_menu.lua so that st_menu.lua stays focused on menu
-- construction.These are the only two functions in the plugin that write directly
-- to config.xml on disk (bypassing the REST API). All other config
-- changes go through PATCH requests to the running daemon.
--
-- This module is required by st_menu.lua, which re-exports both functions
-- in its own return table so that main.lua's mix-in loop picks them up
-- without needing to know about st_settings directly.
--
-- Exports:
--   showPasswordDialog(self, touchmenu_instance)
--   _suggestPassword(self)

local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local ffiutil     = require("ffi/util")
local T           = ffiutil.template

local _    = require("syncthing_i18n").gettext
local U    = require("st_utils")
-- Config directory is resolved per call via U.getConfigDir() so password and
-- username writes cannot use stale path state.  The former module-level `path`
-- constant was removed (BUG-21).

---------------------------------------------------------------------------
-- Password dialog (single dialog, password-first, optional username step)
---------------------------------------------------------------------------
-- Why password-first? Almost every user only wants to set a password —
-- they are happy with the default username "syncthing".  We make the
-- common case one tap and hide username under "Change username".
local showPasswordDialog
showPasswordDialog = function(self, touchmenu_instance)
    if self:isRunning() then
        UIManager:show(ConfirmBox:new{
            text = _(
                "Syncthing must be stopped before changing the password.\n\n"
                .. "Stop Syncthing now and continue?"),
            ok_text     = _("Stop & continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:stop(function()
                    showPasswordDialog(self, touchmenu_instance)
                end)
            end,
        })
        return
    end

    local dlg
    dlg = InputDialog:new{
        title       = _("Web GUI password"),
        input       = self.gui_password or "",
        input_type  = "string",
        text_type   = "password",
        input_hint  = _("Leave empty to remove the password"),
        description = T(_("Username: %1"), self.gui_user or "syncthing"),
        buttons     = {
            {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local new_password = dlg:getInputText()
                        if new_password == "" then new_password = nil end

                        local ok, err = U.setGUIPassword(
                            new_password or "",
                            U.getConfigDir(),
                            self.gui_user)

                        if not ok then
                            -- Surface the error to the user instead of
                            -- silently saving the in-memory copy and
                            -- pretending success.  The password they
                            -- think they set would not actually have
                            -- been written to config.xml.
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = T(_(
                                    "Could not save the password to Syncthing's config file.\n\n"
                                    .. "Details: %1\n\nThe password was NOT changed."),
                                    tostring(err or "unknown error")),
                            })
                            return
                        end

                        self.gui_password = new_password
                        -- Use delSetting when removing the password rather
                        -- than saveSetting(key, nil).  KOReader's
                        -- LuaSettings exposes them as separate methods, and
                        -- the documented way to remove a key is to delete
                        -- it explicitly — saveSetting with nil has
                        -- undocumented behavior across versions.
                        if new_password then
                            G_reader_settings:saveSetting("syncthing_gui_password", new_password)
                        else
                            G_reader_settings:delSetting("syncthing_gui_password")
                        end
						G_reader_settings:saveSetting("syncthing_password_configured", true)
                        UIManager:close(dlg)
                        UIManager:show(InfoMessage:new{
                            timeout = 3,
                            text    = new_password
                                and _("Password saved.\n\nIt will take effect the next time you start Syncthing.")
                                or  _("Password removed.\n\nThe Web GUI will be accessible without a password."),
                        })
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
            {
                {
                    text     = _("Change username"),
                    callback = function()
                        UIManager:close(dlg)
                        local user_dlg
                        user_dlg = InputDialog:new{
                            title      = _("Web GUI username"),
                            input      = self.gui_user or "syncthing",
                            input_type = "string",
                            input_hint = _("Default: syncthing"),
                            buttons    = {{
                                {
                                    text     = _("Cancel"),
                                    callback = function()
                                        UIManager:close(user_dlg)
                                        showPasswordDialog(self, touchmenu_instance)
                                    end,
                                },
                                {
                                    text             = _("Save"),
                                    is_enter_default = true,
                                    callback         = function()
                                        local new_user = user_dlg:getInputText()
                                        if new_user == "" then new_user = "syncthing" end

                                        if self.gui_password then
                                            local ok, err = U.setGUIPassword(
                                                self.gui_password,
                                                U.getConfigDir(),
                                                new_user)
                                            if not ok then
                                                UIManager:show(InfoMessage:new{
                                                    icon = "notice-warning",
                                                    text = T(_(
                                                        "Could not save the username to Syncthing's config file.\n\n"
                                                        .. "Details: %1\n\nThe username was NOT changed."),
                                                        tostring(err or "unknown error")),
                                                })
                                                return
                                            end
                                        end

                                        self.gui_user = new_user
                                        G_reader_settings:saveSetting("syncthing_gui_user", new_user)
                                        UIManager:close(user_dlg)
                                        showPasswordDialog(self, touchmenu_instance)
                                    end,
                                },
                            }},
                        }
                        UIManager:show(user_dlg)
                        user_dlg:onShowKeyboard()
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

---------------------------------------------------------------------------
-- First-run password suggestion (shown after Syncthing is installed)
---------------------------------------------------------------------------
local SKIP_COOLDOWN_DAYS = 7
local SKIP_COOLDOWN_SEC  = SKIP_COOLDOWN_DAYS * 24 * 3600

local function _suggestPassword(self)
    -- Permanent suppression: user has already set a password or chose
    -- "Don't ask again".
    if G_reader_settings:readSetting("syncthing_password_configured") then
        return
    end

    -- Temporary suppression: user clicked "Skip for now" recently.
    local skipped_at = G_reader_settings:readSetting("syncthing_password_skip_at")
    if skipped_at and (os.time() - skipped_at) < SKIP_COOLDOWN_SEC then
        return
    end

    UIManager:show(ConfirmBox:new{
        text = _(
            "Syncthing is installed.\n\n"
            .. "Right now the Web GUI is open to anyone on your Wi-Fi.\n\n"
            .. "Set a password? You can change it anytime from the menu."),
        ok_text     = _("Set password"),
        cancel_text = _("Skip for now"),
        other_buttons = {{
            {
                text     = _("Don't ask again"),
                callback = function()
                    G_reader_settings:saveSetting("syncthing_password_configured", true)
                    G_reader_settings:delSetting("syncthing_password_skip_at")
                end,
            },
        }},
        ok_callback = function()
            G_reader_settings:saveSetting("syncthing_password_configured", true)
            G_reader_settings:delSetting("syncthing_password_skip_at")
            showPasswordDialog(self)
        end,
        cancel_callback = function()
            -- "Skip for now": temporary suppression, ask again after
            -- SKIP_COOLDOWN_DAYS days.
            G_reader_settings:saveSetting("syncthing_password_skip_at", os.time())
        end,
    })
end

---------------------------------------------------------------------------
-- Module exports
-- main.lua mixes these into the Syncthing class, so both are callable as
-- self:_suggestPassword() and self:showPasswordDialog(tmi).
---------------------------------------------------------------------------
return {
    showPasswordDialog = showPasswordDialog,
    _suggestPassword   = _suggestPassword,
}
