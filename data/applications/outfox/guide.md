# Project OutFox: Installation & Configuration Guide

Project OutFox is an extensible rhythm gaming platform based on StepMania. Because official distribution builds are provided as direct binary archives rather than WinGet packages, OutFox is installed manually into your games directory.

## Step-by-Step Installation

1. **Download Archive**:
   - Visit the official download portal: [Project OutFox Downloads](https://projectoutfox.com/download)
   - Download the latest Windows 64-bit release package (e.g., `OutFox-*-Windows-x64.zip` or the community installer).

2. **Extract to Target Location**:
   - Extract the entire contents into your games directory:
     `%GAMES_DIR%\OutFox` (typically `D:\Games\OutFox`).
   - Ensure `OutFox.exe` is located at `%GAMES_DIR%\OutFox\Program\OutFox.exe`.

3. **Initial First-Run Initialization**:
   - Launch `OutFox.exe` once.
   - Wait for the game engine to populate default profile folders and user directories (`Save/`, `Songs/`, `Themes/`).
   - Exit the game from the main menu.

4. **Directory Junctions**:
   - `reglaze` will automatically link `%GAMES_DIR%\OutFox\Songs` and `%GAMES_DIR%\OutFox\Save` to your configured cloud storage (%STREAM% or %DATA_DRIVE%) immediately after this step.
