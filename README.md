
             SYSTEMS AUTOMATION TOOLKIT LAUNCHER (v1.0)

Author:      silver1-1
Version:     1.0
Date:        July 15, 2026
Repository:  https://github.com/silver1-1

------------------------------------------------------------------------
1. OVERVIEW & CAPABILITIES
------------------------------------------------------------------------
The Systems Automation Toolkit Launcher is a dynamic PowerShell command-
line framework designed to act as a unified dashboard for system engineers, 
administrators, and developers. 

Unlike basic static menus, this tool features an underlying JSON-backed 
database, path-normalization algorithms, real-time file-system drift 
detection, interactive tagging, and automatic integration with GitHub 
and local directories.

------------------------------------------------------------------------
2. SYSTEM ARCHITECTURE & FOLDER LAYOUT
------------------------------------------------------------------------
The toolkit relies on a self-contained structure relative to the root 
folder where "ToolkitLauncher.ps1" resides. On first launch, the script 
automatically establishes the directory layout.

*IMPORTANT PATH REQUIREMENT:*
To keep your scripts structured properly, the physical "General" and 
"Misc" directories are maintained as two completely separate folders 
within the workspace.

Project Directory Tree:
YourProjectRoot/
│
├── ToolkitLauncher.ps1        # The main interactive launcher
├── toolkit_config.json        # Unified JSON database (Auto-generated)
├── README.txt                 # This manual
│
└── src/                       # Central script repository
    ├── General/               # Standard administrative automation
    │   └── SampleGeneral.ps1
    │
    └── Misc/                  # Utility or specialized scripts
        └── SampleUtility.ps1

------------------------------------------------------------------------
3. DETAILED FUNCTIONAL GUIDE
------------------------------------------------------------------------


FUNCTION 1: SCRIPT EXPLORER (FOLDER NAVIGATOR)

Accessible via Option [1] on the Main Menu.

* Viewing and Navigating:
  Lists all physical directories found under the `src/` folder, as well 
  as any virtual folders registered in the database.
  - Type the corresponding number to open a folder and view its scripts.

* Adding a New Folder on Disk:
  - Inside the Folder Explorer, type "N" to create a new folder.
  - Enter your folder name. This immediately creates a physical folder 
    on disk inside the `src/` directory.

* Renaming and Merging Folders:
  - Inside the Folder Explorer, type "R".
  - Select the folder you wish to rename.
  - Enter the new target name.
  - SMART COLLISION HANDLING: If you rename a folder to an existing 
    folder name, the launcher asks if you want to MERGE them. Choosing 
    merge will physically relocate all files, re-map their paths in the 
    database, and cleanly delete the old directory.

* Running Scripts with Arguments:
  - Navigate to your folder, select your script, and press "1" to run.
  - You will be prompted: "Enter any arguments for the script".
  - Type arguments exactly as you would on the CLI (e.g., `-Force -Verbose`) 
    or leave it blank for default execution.

* Moving Scripts Between Folders:
  - Open a script's detail page, press "5" (Move to Another Folder).
  - Select from the folder list or type "N" to move it into a brand new folder.
  - The script file and all its listed dependency files will be physically 
    migrated on your hard drive, and the database will be updated.

* Custom Script Metadata:
  - Select a script, press "4" (Edit Metadata).
  - You can safely update its display Name, Description, and trackable 
    Local Path relative to the workspace.



FUNCTION 2: MANUAL LOCAL TOOL REGISTER

Accessible via Option [A] on the Main Menu.

This function allows you to manually register tools that may live outside 
the default workspace, or configure custom configurations before physical 
files are even created.
1. Enter the display name and description.
2. Choose to assign it to an existing folder, or create a new one.
3. Enter the target path. The engine will automatically translate it 
   into a neat, relocatable relative path (e.g., `src\General\mytool.ps1`) 
   if it resides within the project directory.



FUNCTION 3: GITHUB DOWNLOADER & IMPORT SUITE

Accessible via Option [G] on the Main Menu.

Easily pull individual scripts directly from any GitHub repository and 
integrate them cleanly into your launcher.

1. Copy the URL of a script from GitHub. You can copy either the 
   raw user content URL or the standard browser view URL (e.g., 
   `github.com/.../blob/main/script.ps1`).
2. Paste the URL. The launcher automatically converts standard browser 
   URLs into secure Raw User Content endpoints.
3. Confirm or edit the destination filename.
4. Select the target folder.
5. DEPENDENCY DOWNLOADING: You will be asked for "additional files to 
   pull from the same branch (comma separated)". If the script relies 
   on helper configs, assets, or readmes, list them (e.g., `config.json, 
   helper.psm1`). The engine will fetch them from the exact same branch 
   on GitHub and place them right next to your script.



FUNCTION 4: NESTED MANIFEST IMPORTER & EXPORTER

Accessible via Options [I] and [E] on the Main Menu.

This feature allows you to backup, restore, or share entire customized 
configurations of folders, scripts, URLs, tags, and dependencies.

* Exporting [Option E]:
  - Creates a structured JSON manifest detailing every folder and script 
    in your system.
  - Saves as `toolkit_manifest_export.json` (or your chosen name) in 
    your root workspace.
  - Perfect for backing up your profile or creating setup baselines.

* Importing [Option I]:
  - Input the path of a toolkit manifest JSON file.
  - The Importer reads the nested data, creates any missing folders on 
    disk, auto-registers all listed scripts, applies tags, and saves 
    the paths relative to your current machine context.
  - If a script in the manifest exists in your database already, a 
    collision prompt appears, allowing you to rename, ignore, or overwrite.



FUNCTION 5: GLOBAL TAG MANAGER

Accessible via Option [2] on the Main Menu.

Organize, search, and manage scripts by task tags (e.g., "ActiveDirectory", 
"Exchange", "Networking", "Security").

* Global Overview: Displays a unique sorted list of all tags currently 
  assigned to scripts in the database.
* [A]dd New Tag: Create a new tag and immediately select a script to 
  assign it to by inputting its ID.
* [U]pdate Name: Rename a tag globally across every script in the 
  database simultaneously.
* [R]emove Tag: Completely strip a specific tag from all scripts in the 
  system.
* Searching via Tags: Inside any folder explorer, you can search for 
  active tags simply by using the `/s <tagname>` command.



FUNCTION 6: REMOVE TOOL MENU

Accessible via Option [R] on the Main Menu.

A centralized, safe interface to remove tools from your database without 
accidentally breaking your physical scripts.
1. Select the category folder.
2. Select the index number of the script you wish to remove.
3. Confirm the selection to cleanly unregister it from your system config.



FUNCTION 7: SETTINGS & CONFIGURATION

Accessible via Option [S] on the Main Menu.

* Toggle Execution Mode:
  - ClearSession (Default): Runs the script directly inside the launcher's 
    active session, giving you immediate access to variables and speed. 
    Ideal for simple scripts and fast loops.
  - NewWindow: Launches the target script in a completely isolated, 
    independent PowerShell administrative process. The script executes, 
    and keeps the temporary window open so you can read errors or outputs. 
    Once you press Enter, the process terminates and returns you safely 
    to the launcher.

* Force Directory Scan:
  - Bypasses automated drift checks and forces a hard manual rebuild 
    of the workspace index.

------------------------------------------------------------------------
4. AUTOMATED HEALTH & DRIFT DETECTION
------------------------------------------------------------------------
The launcher features a built-in automated "Self-Healing" routine 
on launch:
1. Path Auto-Normalization: If a absolute hardcoded local path is detected 
   (e.g., from an import file), the launcher converts it to a relocatable 
   relative path based on where the project is running.
2. System Drift Check: Every time the launcher starts, it automatically 
   checks for physical changes. If you dropped scripts manually into the 
   `src/` folder via File Explorer, or deleted physical directories on 
   disk, the launcher detects it, updates the database, and self-heals.
3. GitHub Recovery: If a script database record exists but the physical 
   file is deleted, launching the script will prompt: "This file is missing 
   but has a registered GitHub source. Download/Restore now?". Selecting 
   'Y' downloads it back to its physical location.
