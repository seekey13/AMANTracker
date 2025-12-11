# AMANTracker

AMANTracker is an Ashita v4 addon for Final Fantasy XI that provides a GUI tracker for Adventurers' Mutual Aid Network (A.M.A.N.) Training Regimes, displaying real-time progress for your active training targets.

<img width="419" height="192" alt="image" src="https://github.com/user-attachments/assets/55408491-a689-4c94-b8e9-545d010b5282" />


> **Note:**  
> This addon was designed **EXCLUSIVELY** for the [CatsEyeXI private server](https://www.catseyexi.com/) and may not function as intended on retail or other private servers.  The message formats and mechanics are only tested specifically for CatsEyeXI.


## Features

- **Hybrid packet/text detection** - Uses packets for reliable tracking with text fallback
- **Automatic training regime detection** - Detects regime start, confirmation, and cancellation
- **Real-time progress tracking** - Updates kill counts via packet events
- **Persistent storage** - Saves progress across reloads and logins
- **Automatic regime resets** - Detects when training restarts
- **Clean, resizable UI** - Auto-sizing window with progress bars
- **Toggle UI command** - `/at` or `/at ui` to show/hide the tracker
- **Fully automatic** - No setup required, just start training


## Installation

1. Download or clone this repository into your Ashita v4 `addons` folder:

   ```
   git clone https://github.com/seekey13/AMANTracker.git
   ```

2. Start or restart Ashita.
3. Load the addon in-game:

   ```
   /addon load amantracker
   ```


## Commands

- `/at` or `/at ui` - Toggle the UI window visibility


## How It Works

### Hybrid Tracking System
The addon uses a dual-layer approach for maximum reliability:

**Packet-Based Detection** (Primary):
- **Enemy Defeats** - Intercepts action message packet 0x29 (message IDs 6, 646)
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
- Only clears on explicit game events:
  - Training regime cancelled
  - New training regime started

### UI Display
- Toggle visibility with `/at` or `/at ui` command
- Only shows when training is active and parsed
- Auto-resizes height based on number of enemies
- Adjustable width (300-500px)
- Progress bars with kill count overlays
- Clean, minimal interface


## Data Storage

Settings saved to: `~\Ashita\config\addons\AMANTracker\[character_name]\settings.lua`

Stored data includes:
- Active training state
- Enemy list with kill counts
- Target level range
- Training area zone


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

[Commandobill](https://github.com/commandobill), [atom0s](https://github.com/atom0s), and [Carver](https://github.com/CatsEyeXI)

Completely unnecessary AI generated image  
<img width="400" alt="image" src="https://github.com/user-attachments/assets/46efa67b-61c2-4e39-a994-b4d6980d44a3" />


## Changelog

### Version 2.0 (Current)
- **Major Update: Hybrid Packet/Text Detection System**
- Added packet handler module for reliable event detection
- Intercepts action message packets (0x29) for enemy defeats and progress
- Packet-based tracking for defeats (message IDs 6, 646)
- Packet-based progress updates (message IDs 558, 698)
- Packet-based regime reset detection (message ID 643)
- Packet-based regime completion detection (message ID 559)
- Duplicate prevention system (packets take priority over text)
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
