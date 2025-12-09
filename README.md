# AMANTracker

AMANTracker is an Ashita v4 addon for Final Fantasy XI that provides a GUI tracker for Adventurers' Mutual Aid Network (A.M.A.N.) Training Regimes, displaying real-time progress for your active training targets.

> **Note:**  
> This addon was designed **EXCLUSIVELY** for the [CatsEyeXI private server](https://www.catseyexi.com/) and may not function as intended on retail or other private servers.  The message formats and mechanics are only tested specifically for CatsEyeXI.


## Features

- Automatic training regime detection and tracking
- Real-time progress display with progress bars
- Persistent storage across reloads and logins
- Automatic reset on training completion (with repeat detection)
- Job change detection (clears data on job switch)
- Zone-safe tracking (maintains data across zone changes)
- Clean, resizable UI window
- No commands required - fully automatic


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


## How It Works

### Automatic Detection
- Detects when you interact with A.M.A.N. training tomes
- Parses training regime details (targets, level range, training area)
- Tracks enemy defeats and updates progress in real-time
- Handles both repeating and non-repeating training regimes

### Progress Tracking
- Monitors combat messages for enemy defeats
- Updates kill counts automatically
- Displays progress bars for each target enemy
- Shows training area and level range

### Data Persistence
- Saves active training data to disk
- Restores progress on addon reload or login
- Automatically clears on regime completion or cancellation
- Resets progress when training regime restarts

### Smart Resets
- Clears data when training is cancelled
- Resets counts when regime repeats (after completion)
- Completely clears when non-repeating regime completes
- Clears data on job change

### UI Display
- Only shows when training is active and parsed
- Auto-resizes height based on number of enemies
- Adjustable width (300-500px)
- Progress bars with kill count overlays
- Clean, minimal interface


## Data Storage

Settings saved to: `Ashita/config/addons/AMANTracker/settings.json`

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

## Changelog

### Version 1.0 (Current)
- Initial release
- Automatic training regime detection
- Real-time progress tracking with progress bars
- Persistent storage across reloads
- Job change detection and reset
- Zone-safe data preservation
- Repeat vs. non-repeat regime handling
- Modular architecture with parser and UI modules
- DRY principle refactoring (consolidated helpers, dispatch tables, string constants)
