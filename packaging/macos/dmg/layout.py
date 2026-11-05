"""Finder layout; positions are in points, matching render-background.m."""

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((200, 300), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"Pressay.app": (170, 178), "Applications": (490, 178)}
# Do not set hide_extensions on the signed app: dmgbuild adds FinderInfo to the
# bundle, which codesign --verify --strict correctly rejects as detritus.
