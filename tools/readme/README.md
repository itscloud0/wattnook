# README images

```sh
# Renders, incl. readme-menu-0…3.tiff (the menu-bar item through one rotation)
WATTNOOK_README=1 /tmp/dash /tmp/renders     # build /tmp/dash as in CLAUDE.md
cd /tmp/renders && swift "$OLDPWD/tools/readme/menu-bar.swift" /tmp/menu-bar.gif readme-menu-{0,1,2,3}.tiff
cp /tmp/menu-bar.gif docs/images/; cp readme-charging.png "$OLDPWD/docs/images/battery.png"
cd "$OLDPWD" && swift tools/readme/social-preview.swift docs/images/social-preview.png \
  tools/app/WattNook-Icon.png docs/images/battery.png /tmp/menu-bar.png
```

`social-preview.png` is uploaded by hand: repo Settings → General → Social preview.
