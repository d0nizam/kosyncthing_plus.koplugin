-- _meta.lua — KOReader plugin manifest.
--
-- Version is plugin-scoped, NOT the bundled Syncthing binary's version
-- (which is shown separately in About).

local _ = require("syncthing_i18n").gettext

return {
    fullname    = _("KOSyncthing+"),
    description = _([[Continuously sync files with other devices in a peer-to-peer manner.]]),
    version     = "v1.2.0",
}
