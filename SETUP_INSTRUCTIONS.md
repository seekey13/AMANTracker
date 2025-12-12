# AMANTracker - Hybrid UI Setup Instructions

The addon has been successfully converted to use the hybrid ImGui + GDI Fonts approach for transparent floating text!

## Required Setup Step

To complete the setup, you need to copy the `gdifonts` directory from the ffxi-trainmon addon:

1. Copy the entire `gdifonts` folder from:
   ```
   c:\Users\dcich\OneDrive\addons\ffxi-trainmon\gdifonts
   ```

2. Paste it into the AMANTracker addon directory:
   ```
   r:\CatsEyeXI\catseyexi-client\Ashita\addons\AMANTracker\gdifonts
   ```

Your final directory structure should look like:
```
AMANTracker/
  ├── AMANTracker.lua
  ├── LICENSE
  ├── README.md
  ├── gdifonts/          <-- Required directory
  │   ├── include.lua
  │   └── ... (other gdifonts files)
  └── lib/
      ├── family.lua
      ├── packet_handler.lua
      ├── parser.lua
      └── tracker_ui.lua
```

## What Changed

### Visual Changes
- **Transparent Background**: The window no longer has a solid background
- **Outlined Text**: All text now has black outlines for better readability over the game
- **Same Layout**: The data format and layout remain exactly as before:
  - Training Area: [training area name]
  - Target #1 Name
  - [progress bar and #/# count]
  - Target #2 Name
  - [progress bar and #/# count]
  - Level Range: #~#

### Technical Changes
- Converted from pure ImGui to hybrid ImGui + GDI Fonts approach
- Added GDI font objects for superior text rendering
- Implemented absolute positioning for text elements
- Added proper cleanup on addon unload
- Progress bars are now text-based with visual indicators: `[==========----------] 10/20`

## Font Customization

You can customize the fonts by editing the `font_settings` table in `lib/tracker_ui.lua`:

```lua
-- Font Settings
local font_settings = T{
    title = T{
        font_color = 0xFFFFFF99,        -- Light yellow (ARGB format)
        font_family = 'Consolas',
        font_height = 18,
        outline_width = 2,
    },
    entry = T{
        font_color = 0xFFFFFFFF,        -- White
        font_height = 16,
    },
    progress = T{
        font_color = 0xFF00FF00,        -- Green
        font_height = 14,
    },
};
```

### Color Format
Colors use ARGB hex format: `0xAARRGGBB`
- AA = Alpha (opacity): FF = fully opaque
- RR = Red
- GG = Green  
- BB = Blue

Examples:
- White: `0xFFFFFFFF`
- Yellow: `0xFFFFFF00`
- Green: `0xFF00FF00`
- Red: `0xFFFF0000`
- Light Yellow: `0xFFFFFF99`

## Testing

After copying the gdifonts directory:
1. Load the addon in-game: `/addon load amantracker`
2. Start an AMAN training regime
3. The tracker should appear with transparent background and outlined text
4. Text should be clearly readable over the game background
5. Use `/amantracker toggle` to show/hide the window

## Troubleshooting

If you see errors about missing gdifonts:
- Verify the gdifonts directory was copied correctly
- Make sure all files from the trainmon gdifonts folder are present
- Reload the addon: `/addon reload amantracker`

If the window appears but text is invisible:
- Check that the font family (Consolas) is installed on your system
- Try changing `font_family` to 'Arial' or 'Tahoma' in the settings
