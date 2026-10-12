# dmgbuild settings for the download's disk image: the app on the left, Applications on the right,
# the background with the "drag it in" arrow between them (Resources/dmg). Used by scripts/release.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=build/CineNotch.app CineNotch build/CineNotch.dmg
import os.path

app = defines.get("app", "build/CineNotch.app")  # noqa: F821 (dmgbuild provides `defines`)
name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"  # the mounted volume shows the app's icon

# The background is 660 x 440 points (1x and 2x in one TIFF); the icons sit on the arrow's ends.
# The window's height includes Finder's title bar, which differs between macOS versions, so the
# background runs taller than the visible area and keeps everything above its last 80 points.
background = "Resources/dmg/background.tiff"
window_rect = ((200, 140), (660, 432))
icon_locations = {name: (180, 190), "Applications": (480, 190)}
icon_size = 128
text_size = 13
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
