# AMANTracker

AMANTracker is an Ashita v4 addon for Final Fantasy XI that provides a GUI tracker for Adventurers' Mutual Aid Network (A.M.A.N.) Training Regimes, displaying real-time progress for your active training targets.

Two UI Options: New transparent floating text using Thorny's gdifonts

<img width="340" alt="image" src="https://github.com/user-attachments/assets/499aaed2-e991-4bbb-ba3e-26a7a6165710" />


Or the typical ImGui

<img width="340" alt="image" src="https://github.com/user-attachments/assets/55408491-a689-4c94-b8e9-545d010b5282" />


> **Note:**  
> This addon was designed **EXCLUSIVELY** for the [CatsEyeXI private server](https://www.catseyexi.com/) and may not function as intended on retail or other private servers.  The message formats and mechanics are only tested specifically for CatsEyeXI.


## Features

- **Dual UI Modes** - Choose between transparent floating text (GDI Fonts) or classic solid window (ImGui)
- **Transparent Overlay** - Default mode uses outlined text that floats over the game (GDI Fonts mode)
- **Classic Window Mode** - Traditional ImGui window with background (ImGui mode)
- **Family-based mob tracking** - Supports "Members of the X Family" training regimes
- **16 mob families** - Pre-configured family definitions (Bat, Gigas, Goblin, Skeleton, etc.)
- **Smart pattern matching** - Automatically detects family patterns vs exact mob names
- **Hybrid packet/text detection** - Uses packets for reliable tracking with text fallback
- **Automatic training regime detection** - Detects regime start, confirmation, and cancellation
- **Real-time progress tracking** - Updates kill counts via packet events
- **Persistent storage** - Saves progress and UI mode preference across sessions
- **Automatic regime resets** - Detects when training restarts
- **Draggable UI** - Click and drag to reposition the tracker
- **Fully automatic** - No setup required, just start training


## Installation

1. Download or clone this repository into your Ashita v4 `addons` folder:

   ```
   git clone https://github.com/seekey13/AMANTracker.git
   ```

2. **For GDI Fonts mode (transparent text)**: Copy the `gdifonts` directory from [ffxi-trainmon](https://github.com/ThornyFFXI/ffxi-trainmon) into the AMANTracker folder
   - The ImGui mode works without gdifonts

3. Start or restart Ashita.
4. Load the addon in-game:

   ```
   /addon load amantracker
   ```
## Commands

- `/at` - Show help and available commands
- `/at ui` - Toggle the UI window visibility
- `/at ui gdifonts` - Switch to transparent floating text mode (default)
- `/at ui imgui` - Switch to classic solid window mode
- `/at clear` - Clear current training data and reset tracker
- `/at debug` - Toggle death-packet logging (prints message id, actor, target, target index, credit decision and resolved name)


## How It Works

### Hybrid Tracking System
The addon uses a dual-layer approach for maximum reliability:

**Packet-Based Detection** (Primary):
- **Enemy Defeats** - Intercepts action message packet 0x29 (death message IDs 6, 20, 113, 406, 605, 646); deaths with no usable actor (20, 605) are credited only if the dying mob is on an engaged-mob list built from Action packets (0x28), which is cleared on zone change (packets 0x0A/0x0B)
- **Progress Updates** - Reads progress directly from packets (message IDs 558, 698)
- **Regime Resets** - Detects "begin anew" via packet (message ID 643)
- **Regime Completion** - Monitors completion messages (message ID 559)

**Text-Based Detection** (Fallback):
- **Tome Interaction** - Detects A.M.A.N. tome access from chat
- **Training Start** - Parses enemy list and training details
- **Regime Confirmation** - Detects "New training regime registered!"
- **Regime Cancellation** - Detects "Training regime canceled."

This hybrid approach ensures:
- No duplicate processing (packet data takes priority)
- Reliable tracking even if packets change
- Compatibility with text-only scenarios
- Maximum accuracy for kill counting

### Progress Tracking
- Intercepts action packets for instant defeat detection
- Extracts enemy names directly from entity data
- Updates kill counts in real-time
- Prevents duplicate counting from text messages
- Displays progress bars for each target enemy

### Data Persistence
- Saves active training data to disk
- Restores progress on addon reload or login
- Only clears on explicit game events (cancellation or new regime)

### UI Display
- Two display modes: GDI Fonts (transparent) and ImGui (solid window)
- Toggle visibility with `/at` or `/at ui` command
- Switch modes with `/at ui gdifonts` or `/at ui imgui`
- Only shows when training is active and parsed
- **GDI Fonts Mode (Default)**:
  - Transparent background with outlined text
  - Floats over the game with no window borders
  - Draggable by clicking anywhere on the text
  - ImGui progress bars with outlined text labels
  - Consistent spacing regardless of text content
- **ImGui Mode**:
  - Traditional solid window with background
  - Title bar and window decorations
  - Auto-resizes height based on number of enemies
  - Adjustable width (300-500px)
- Progress bars with kill count overlays
- UI mode preference saved automatically


## Data Storage

Settings saved to: `~\Ashita\config\addons\AMANTracker\[character_name]\settings.lua`

Stored data includes:
- Active training state
- Enemy list with kill counts
- Target level range
- Training area zone
- UI mode preference (gdifonts or imgui)


## Requirements

- Ashita v4
- CatsEyeXI server


## License

MIT License. See [LICENSE](LICENSE) for details.

## Credits

- Author: Seekey
- Inspired by the need to track A.M.A.N. training progress without staring at your chat log.


## Support

Open an issue or pull request on the [GitHub repository](https://github.com/seekey13/AMANTracker) if you have suggestions or encounter problems.

## Special Thanks

[Commandobill](https://github.com/commandobill), [atom0s](https://github.com/atom0s), [Carver](https://github.com/CatsEyeXI), and [Thorny](https://github.com/ThornyFFXI)

Completely unnecessary AI generated image  
<img width="400" alt="image" src="https://github.com/user-attachments/assets/46efa67b-61c2-4e39-a994-b4d6980d44a3" />



## Changelog
### Version 2.8 (Current)
- **Fixed Actor-less Kill Credit**: Self-destruct and damage-over-time deaths arrive as action message 20 ("The Bomb falls to the ground."), which names no actor the client can match against the party, so the kill was silently dropped
- **Expanded Death Message Detection**: Added messages 20, 113 (spell), 406 (weapon skill) and 605 (additional effect) alongside the existing 6 and 646
- **Added Engaged-Mob List**: Built from Action packets (0x28), tracking every mob a party member or their pet has acted on; an actor-less death is credited only if the dying mob is on it
- **Engagement Expiry**: Each entry carries a 15-minute TTL, checked lazily whenever that server ID is looked up again -- a stale entry otherwise sits until the next zone change, when every entry is cleared outright since server IDs are reused
- **Monster-Only Credit**: A death is only credited when the dying entity is actually a monster, so a party member who dies after being cured can never be counted as a kill
- **New `/at debug` Command**: Logs every death message with its actor, target, target index, credit decision and resolved name
- **Removed Dead Code**: Dropped the unused `get_player_id` helper

### Version 2.7
- **Fixed Startup Display**: The tracker no longer stays hidden when the addon loads while the game is still booting. Ashita only hands an addon the character's saved settings once you log in, so the saved regime, UI mode, and window visibility are now restored on that login event instead of only at load. `/at ui` is no longer needed after every launch.
- **Fixed UI Mode Reset**: `ui_mode` is no longer overwritten when hunt progress is saved, so `/at ui imgui` sticks across sessions.

### Version 2.6
- **Enhanced Matching Logic**: Updated matching logic to accommodate when enemy is a Summit of the Stars target
- **Fixed Plural Issue**: Fixed plural handling for Leech/Leeches

### Version 2.5 
- **gdifonts Folder**: Add contents of gdifonts folder to release.

### Version 2.4
- **New Mob Family**: Added Mandragora family with support for Mandragora, Lycopodium, Pygmaioi, and Adenium variants.  **delukard** again with the find.

### Version 2.3
- **Enhanced Plural Detection**: Added support for words ending in "y" that become "ies" in plural form (e.g., Damselfly → Damselflies)
- **New Mob Family**: Added Crab family with support for Crab, Snipper, Cutter, Ironshell, and Claw variants
- **Fixed Family Pattern Matching**: Corrected Lua pattern syntax in `extract_family_type()` - replaced invalid `(?:the )` regex syntax with proper Lua patterns to ensure "Members of the X Family" patterns are correctly identified
- Updated family list documentation
- Special thanks to **delukard** who reported the bugs.

### Version 2.2
- **Major Feature: Dual UI Mode System**
- Added GDI Fonts mode with transparent floating text (default)
- Added ImGui mode to preserve classic solid window experience
- New commands: `/at ui gdifonts` and `/at ui imgui` to switch modes
- **GDI Fonts Mode Features**:
  - Transparent background with no window decorations
  - Outlined text for superior readability over game background
  - Draggable by clicking anywhere on the text area
  - Hybrid rendering: ImGui progress bars combined with GDI outlined text
  - Consistent spacing using font height instead of measured text (no descender issues)
  - Customizable fonts, colors, and outline settings
- **ImGui Mode**:
  - Preserves original solid window appearance
  - Traditional title bar and window background
  - Fallback option if gdifonts isn't available
- UI mode preference saved and restored across sessions
- Added `set_ui_mode()` function for runtime mode switching
- Split rendering into separate functions for each mode
- Proper GDI object cleanup when switching modes or unloading
- Credits to [Thorny](https://github.com/ThornyFFXI) for the gdifonts library

### Version 2.1
- **Major Feature: Family-Based Mob Tracking**
- Added support for "Members of the X Family" training regimes
- New family module with 16 pre-configured mob families
- Smart pattern matching: automatic detection of family vs exact name patterns
- Case-insensitive family lookup with inclusion/exclusion rules
- Substring matching for inclusions, substring exclusion support
- Match type optimization ('exact' vs 'family') for performance
- Added `/at test <enemy_name>` command for debugging family matches
- Fixed Records of Eminence interference (removed message ID 698 processing)
- Improved packet handling to prevent duplicate defeat detection
- Custom print functions for categorized output (printf, warnf, errorf)
- Enhanced debug output for troubleshooting

**Supported Families:**
- Bat/Bats, Gigas, Goblin, Pugil, Evil Weapon, Yagudo, Doll, Skeleton
- Shadow, Elemental, Golem, Sahagin, Antica, Worm, Sabotender, Tonberry, Bee, Crab

### Version 2.0
- **Major Update: Hybrid Packet/Text Detection System**
- Added packet handler module for reliable event detection
- Intercepts action message packets (0x29) for enemy defeats and progress
- Packet-based tracking for defeats (message IDs 6, 20, 113, 406, 605, 646); actor-less deaths (20, 605) credited via an engaged-mob list built from Action packets (0x28), cleared on zone change (0x0A/0x0B)
- Packet-based progress updates (message ID 558 for AMAN-specific tracking)
- Packet-based regime reset detection (message ID 643)
- Packet-based regime completion detection (message ID 559)
- Text-based fallback for tome interaction, regime start, confirmation, and cancellation
- Entity name extraction directly from game memory
- Improved accuracy and reliability for kill counting

### Version 1.1
- **Simplified Tracking Logic**
- Removed job change detection and automatic clearing (caused false positives during zoning)
- Removed automatic clearing on regime completion without reset detection
- Added `/at` and `/at ui` commands to toggle UI visibility
- Improved data persistence - only clears on explicit cancellation or new regime start
- More reliable tracking with fewer edge cases

### Version 1.0
- Initial release
- Automatic training regime detection
- Real-time progress tracking with progress bars
- Persistent storage across reloads
- Zone-safe data preservation
- Modular architecture with parser and UI modules
- DRY principle refactoring (consolidated helpers, dispatch tables, string constants)
