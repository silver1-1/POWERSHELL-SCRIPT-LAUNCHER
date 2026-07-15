# Systems Automation Toolkit.ps1
# Requires -RunAsAdministrator

<#
.SYNOPSIS
    An interactive PowerShell script launcher interface.

.DESCRIPTION
    This automated tool dynamically scans dedicated script directories 
    and provides a clean, interactive command-line menu to quickly 
    select and execute scripts.

.NOTES
    Script Name: PowerShell Toolkit Script Launcher
    Version:     1.0
    Created By:  silver1-1
    Date:        July 15, 2026
    Run with: powershell -ExecutionPolicy Bypass -File "C:\FILEPATHHERE\SYSTEMS AUTOMATION TOOLKIT\ToolkitLauncher.ps1"
    OR Make a shortcut and Set to run as a Administrator.

.EXAMPLE
    .\ScriptLauncher.ps1
#>

# 1. Enforce Administrative Privileges
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[-] ERROR: This toolkit launcher requires Administrator privileges." -ForegroundColor Red
    Read-Host "Press Enter to exit..."
    exit
}

# 2. Config & Path Init (Self-Detecting root)
$ConfigPath = "$PSScriptRoot\toolkit_config.json"
$DefaultScriptDir = "$PSScriptRoot\src"
if (-not (Test-Path -Path $DefaultScriptDir)) { New-Item -ItemType Directory -Path $DefaultScriptDir -Force | Out-Null }

# Global State
$GlobalConfig = @{
    Settings = @{
        ExecutionMode = "ClearSession" # Options: ClearSession, NewWindow
    }
    Scripts = @()
}

# --- Robust Path Translators ---

# Translates relative paths from the config back into live absolute system paths (strictly relative to script root)
function Get-AbsolutePath {
    param ([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    $Combined = Join-Path $PSScriptRoot $Path
    return [System.IO.Path]::GetFullPath($Combined).TrimEnd('\')
}

# Translates absolute paths inside the workspace to relative paths (e.g., 'src\General\script.ps1')
function Get-RelativePath {
    param ([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    
    $AbsPath = Get-AbsolutePath -Path $Path
    $NormalizedRoot = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    
    if ($AbsPath.StartsWith($NormalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $Rel = $AbsPath.Substring($NormalizedRoot.Length)
        if ($Rel.StartsWith("\")) { $Rel = $Rel.Substring(1) }
        return $Rel
    }
    return $AbsPath # Keep external absolute paths as-is
}

# Scans physical folders under \src, combines with database, and enforces "General" & "Misc" defaults
function Get-AllFolders {
    $PhysicalFolders = @()
    if (Test-Path $DefaultScriptDir) {
        $PhysicalFolders = Get-ChildItem -Path $DefaultScriptDir -Directory | Select-Object -ExpandProperty Name
    }
    $ManifestFolders = @()
    if ($null -ne $GlobalConfig.Scripts) {
        $ManifestFolders = $GlobalConfig.Scripts.Category | Select-Object -Unique
    }
    
    # Enforce default folders are always in the list
    $DefaultFolders = @("General", "Misc")
    
    # Combine, filter out blank space, deduplicate, and sort
    $Combined = @($PhysicalFolders + $ManifestFolders + $DefaultFolders) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique | Sort-Object
    return $Combined # Returning flat array allows @(...) to handle it perfectly
}

# Creates a physical category directory on disk
function New-PhysicalFolder {
    param ([string]$FolderName)
    if ([string]::IsNullOrWhiteSpace($FolderName)) { return }
    $Path = Join-Path $DefaultScriptDir $FolderName
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# Self-Heals missing folder structures on launch
function Sync-FolderStructure {
    $Folders = @(Get-AllFolders)
    foreach ($Folder in $Folders) {
        New-PhysicalFolder -FolderName $Folder
    }
}

# Re-downloads missing physical assets if they are backed by GitHub
function Restore-MissingScript {
    param ($Script)
    $AbsPath = Get-AbsolutePath -Path $Script.LocalPath
    $Dir = Split-Path $AbsPath -Parent
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    
    if (-not [string]::IsNullOrWhiteSpace($Script.GitHubRawUrl)) {
        Write-Host "[*] Script file is missing. Restoring from GitHub source..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $Script.GitHubRawUrl -OutFile $AbsPath -ErrorAction Stop
            Write-Host "[+] Successfully restored file to: $AbsPath" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "[-] Auto-restore failed: $_" -ForegroundColor Red
        }
    }
    return $false
}

# Helper: Move Physical Script File and Dependencies
function Move-PhysicalScriptFile {
    param ($Script, $NewCategory)
    $OldPath = Get-AbsolutePath -Path $Script.LocalPath
    
    $FileName = Split-Path $OldPath -Leaf
    $NewDir = Join-Path $DefaultScriptDir $NewCategory
    if (-not (Test-Path $NewDir)) { New-Item -ItemType Directory -Path $NewDir -Force | Out-Null }
    $NewPath = Join-Path $NewDir $FileName
    
    if (Test-Path $OldPath -PathType Leaf) {
        Move-Item -Path $OldPath -Destination $NewPath -Force -ErrorAction SilentlyContinue
    }
    $Script.LocalPath = Get-RelativePath -Path $NewPath

    # Move additional files/dependencies physically if configured
    if ($null -ne $Script.AdditionalFiles) {
        $NewAddFiles = @()
        foreach ($File in $Script.AdditionalFiles) {
            $OldFilePath = Get-AbsolutePath -Path $File
            if (Test-Path $OldFilePath -PathType Leaf) {
                $DepFileName = Split-Path $OldFilePath -Leaf
                $NewDepPath = Join-Path $NewDir $DepFileName
                Move-Item -Path $OldFilePath -Destination $NewDepPath -Force -ErrorAction SilentlyContinue
                $NewAddFiles += Get-RelativePath -Path $NewDepPath
            } else {
                $NewAddFiles += Get-RelativePath -Path $File
            }
        }
        $Script.AdditionalFiles = $NewAddFiles
    }
}

# Helper: Collision Resolver Utility
function Resolve-ScriptCollision {
    param ($IncomingScript, $ExistingScript, $Folder)
    Write-Host "`n[Conflict] A script named '$($IncomingScript.Name)' already exists in folder '$Folder'." -ForegroundColor Yellow
    Write-Host "  1. Change incoming script name"
    Write-Host "  2. Keep original (Ignore/Discard new script)"
    Write-Host "  3. Overwrite the old script with the new one"
    
    $Choice = (Read-Host "Select Resolution (1-3)").Trim()
    switch ($Choice) {
        "1" {
            $NewName = (Read-Host "Enter new unique name (e.g. Script_v2.ps1)").Trim()
            if (-not [string]::IsNullOrWhiteSpace($NewName)) {
                $IncomingScript.Name = $NewName
                $OldPath = Get-AbsolutePath -Path $IncomingScript.LocalPath
                if (-not [string]::IsNullOrWhiteSpace($OldPath)) {
                    $Dir = Split-Path $OldPath -Parent
                    $IncomingScript.LocalPath = Get-RelativePath -Path (Join-Path $Dir $NewName)
                }
                return $IncomingScript
            }
        }
        "3" {
            # Delete old database record
            $GlobalConfig.Scripts = @($GlobalConfig.Scripts | Where-Object { $_.ID -ne $ExistingScript.ID })
            # Delete physical file
            $OldPhys = Get-AbsolutePath -Path $ExistingScript.LocalPath
            if (Test-Path $OldPhys -PathType Leaf) {
                Remove-Item -Path $OldPhys -Force -ErrorAction SilentlyContinue
            }
            return $IncomingScript
        }
        "2" {
            return $null
        }
    }
    return $null
}

# 3. Database Functions with Dynamic Path Migrator & Self-Deduplicator
function Load-Catalog {
    if (Test-Path -Path $ConfigPath) {
        try {
            $Data = ConvertFrom-Json (Get-Content -Raw -Path $ConfigPath)
            
            # Schema Migration Engine
            if ($Data -is [Array]) {
                $GlobalConfig.Scripts = @($Data)
            } elseif ($null -ne $Data.Scripts) {
                $GlobalConfig.Scripts = @($Data.Scripts)
                if ($null -ne $Data.Settings) {
                    if ($null -ne $Data.Settings.ExecutionMode) { $GlobalConfig.Settings.ExecutionMode = $Data.Settings.ExecutionMode }
                }
            } else {
                $GlobalConfig.Scripts = @()
            }
        } catch {
            $GlobalConfig.Scripts = @()
        }
    }
    
    $NormalizedScripts = @()
    foreach ($Item in $GlobalConfig.Scripts) {
        if (-not $Item.PSObject.Properties['Category']) { $Item | Add-Member -NotePropertyName "Category" -NotePropertyValue "General" }
        if (-not $Item.PSObject.Properties['Description']) { $Item | Add-Member -NotePropertyName "Description" -NotePropertyValue "" }
        if (-not $Item.PSObject.Properties['Tags']) { $Item | Add-Member -NotePropertyName "Tags" -NotePropertyValue @() }
        if (-not $Item.PSObject.Properties['GitHubRawUrl']) { $Item | Add-Member -NotePropertyName "GitHubRawUrl" -NotePropertyValue "" }
        if (-not $Item.PSObject.Properties['AdditionalFiles']) { $Item | Add-Member -NotePropertyName "AdditionalFiles" -NotePropertyValue @() }
        
        # --- PATH MIGRATION: Auto-Heal older absolute/corrupt paths ---
        if (-not [string]::IsNullOrWhiteSpace($Item.LocalPath)) {
            if ($Item.LocalPath -match "src[\/\\].*$") {
                $Item.LocalPath = $Matches[0]
            }
            $Item.LocalPath = Get-RelativePath -Path $Item.LocalPath
        }

        # Auto-Heal Dependency absolute paths
        if ($null -ne $Item.AdditionalFiles) {
            $HealedAddFiles = @()
            foreach ($File in $Item.AdditionalFiles) {
                if ($File -match "src[\/\\].*$") {
                    $File = $Matches[0]
                }
                $HealedAddFiles += Get-RelativePath -Path $File
            }
            $Item.AdditionalFiles = $HealedAddFiles
        } else {
            $Item.AdditionalFiles = @()
        }

        $Item.Tags = if ($null -eq $Item.Tags) { @() } else { @($Item.Tags) }
        $NormalizedScripts += $Item
    }

    # --- DEDUPLICATION PASS (Self-Heals any duplicated catalog records) ---
    $DeduplicatedScripts = @()
    $SeenPaths = @{}
    foreach ($Item in $NormalizedScripts) {
        $NormPath = Get-RelativePath -Path $Item.LocalPath
        if (-not $SeenPaths.ContainsKey($NormPath)) {
            $SeenPaths[$NormPath] = $true
            $DeduplicatedScripts += $Item
        }
    }
    
    $GlobalConfig.Scripts = $DeduplicatedScripts
    Save-Catalog # Immediately commit healed structural state to config
}

function Save-Catalog {
    $Json = ConvertTo-Json $GlobalConfig -Depth 5
    Set-Content -Path $ConfigPath -Value $Json -Force
}

# 4. Auto-Scan Engine
function Sync-LocalFolder {
    Write-Host "[*] Scanning '$DefaultScriptDir' for unmanaged scripts..." -ForegroundColor Cyan
    $Files = Get-ChildItem -Path $DefaultScriptDir -Filter "*.ps1" -Recurse -File
    $NewCount = 0
    
    foreach ($File in $Files) {
        $AbsolutePath = $File.FullName
        $RelativePath = Get-RelativePath -Path $AbsolutePath
        
        $Exists = $GlobalConfig.Scripts | Where-Object { (Get-RelativePath -Path $_.LocalPath) -eq $RelativePath }
        
        if (-not $Exists) {
            $RelativeDir = Split-Path $AbsolutePath -Parent
            $CategoryName = "General"
            if ($RelativeDir -ne $DefaultScriptDir) {
                $CategoryName = Split-Path $RelativeDir -Leaf
            }
            
            $NewID = if ($GlobalConfig.Scripts.Count -gt 0) { ($GlobalConfig.Scripts | Measure-Object -Property ID -Maximum).Maximum + 1 } else { 1 }
            $NewScript = [PSCustomObject]@{
                ID              = $NewID
                Name            = $File.BaseName
                Category        = $CategoryName
                LocalPath       = $RelativePath
                Description     = "Auto-scanned tool from system source folder."
                Tags            = @()
                GitHubRawUrl    = ""
                AdditionalFiles = @()
            }
            $GlobalConfig.Scripts += $NewScript
            $NewCount++
        }
    }
    if ($NewCount -gt 0) {
        Save-Catalog
        Write-Host "[+] Success: Integrated $NewCount new tool(s) from 'src'." -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
}

# 5. Smart Change Detection Engine
function Test-SourceDirectoryChanges {
    # If the database or source folder doesn't exist, we must sync.
    if (-not (Test-Path -Path $ConfigPath)) { return $true }
    if (-not (Test-Path -Path $DefaultScriptDir)) { return $true }

    $PhysicalFiles = Get-ChildItem -Path $DefaultScriptDir -Filter "*.ps1" -Recurse -File
    $PhysicalFolders = Get-ChildItem -Path $DefaultScriptDir -Directory | Select-Object -ExpandProperty Name

    # If the file counts mismatch, physical additions or deletions happened.
    if ($PhysicalFiles.Count -ne $GlobalConfig.Scripts.Count) { return $true }

    # If the category folders mismatch catalog configurations, folder structure changed.
    $CatalogCategories = $GlobalConfig.Scripts.Category | Select-Object -Unique | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $FolderDiff = Compare-Object $PhysicalFolders $CatalogCategories -ErrorAction SilentlyContinue
    if ($null -ne $FolderDiff) { return $true }

    # Deep Check: Make sure all physical files are mapped accurately in the database
    foreach ($File in $PhysicalFiles) {
        $RelPath = Get-RelativePath -Path $File.FullName
        $Match = $GlobalConfig.Scripts | Where-Object { (Get-RelativePath -Path $_.LocalPath) -eq $RelPath }
        if (-not $Match) { return $true }
    }

    # Reverse Deep Check: Verify there are no dead records pointing to missing physical files
    foreach ($Script in $GlobalConfig.Scripts) {
        $AbsPath = Get-AbsolutePath -Path $Script.LocalPath
        if (-not (Test-Path $AbsPath -PathType Leaf)) { return $true }
    }

    # Zero differences found
    return $false
}

# --- Initialize Database ---
Load-Catalog

# Run sync ONLY if structural shifts or physical folder drift are detected
if (Test-SourceDirectoryChanges) {
    Write-Host "[*] System drift or missing files detected. Refreshing toolkit mapping..." -ForegroundColor Yellow
    Sync-FolderStructure
    Sync-LocalFolder
}

# 6. Execution Pipeline
function Invoke-Script {
    param ($Script, [string]$Arguments = "")
    $ResolvedPath = Get-AbsolutePath -Path $Script.LocalPath
    
    # Attempt to restore from disk if missing
    if (-not (Test-Path $ResolvedPath -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($Script.GitHubRawUrl)) {
            Write-Host "[-] Missing execution asset: $ResolvedPath" -ForegroundColor Red
            $Confirm = Read-Host "This file is missing but has a registered GitHub source. Download/Restore now? (Y/N)"
            if ($Confirm.ToUpper() -eq 'Y') {
                if (-not (Restore-MissingScript -Script $Script)) {
                    Read-Host "Press Enter to return..."
                    return
                }
            } else {
                return
            }
        } else {
            Write-Host "[-] Execution Aborted: Script file missing at: $ResolvedPath" -ForegroundColor Red
            Read-Host "Press Enter to return..."
            return
        }
    }

    $Mode = $GlobalConfig.Settings.ExecutionMode
    if ($Mode -eq "NewWindow") {
        Write-Host "[*] Launching execution in isolated PowerShell process..." -ForegroundColor Cyan
        $ArgList = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command", "& { try { Clear-Host; & '$ResolvedPath' $Arguments } catch { Write-Host 'Script runtime crash detected!' -ForegroundColor Red; Write-Error `"$_`"; } finally { Write-Host ''; Write-Host 'Session finished. Press Enter to return to launcher...' -ForegroundColor DarkGray; [void]([Console]::ReadLine()) } }"
        )
        Start-Process powershell -ArgumentList $ArgList -Wait
    } else {
        Clear-Host
        Write-Host "================ [ Executing: $($Script.Name) ] ================" -ForegroundColor Cyan
        try {
            if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
                Invoke-Expression "& '$ResolvedPath' $Arguments"
            } else {
                & $ResolvedPath
            }
        } catch {
            Write-Host "`n[-] Runtime Error Encountered:" -ForegroundColor Red
            Write-Host "Details: $_" -ForegroundColor DarkRed
        } finally {
            Write-Host "`n==========================================================" -ForegroundColor Cyan
            Read-Host "Press Enter to return to main menu..."
        }
    }
}

# 7. Master Loop Menu (Labeled to support breaking from nested switches)
:MenuLoop do {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "           SYSTEMS AUTOMATION TOOLKIT             " -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Green
    Write-Host "Main Menu:" -ForegroundColor Yellow
    Write-Host "  1. Script Explorer (Folders)"
    Write-Host "  2. Global Tag Manager"
    Write-Host "  A. Add New Tool Manually"
    Write-Host "  G. Import/Download from GitHub"
    Write-Host "  I. Import Nested Folder Manifest"
    Write-Host "  E. Export Nested Folder Manifest"
    Write-Host "  R. Remove Tool Menu"
    Write-Host "  S. Settings & Configuration"
    Write-Host "  Q. Quit"
    Write-Host "--------------------------------------------------" -ForegroundColor Green

    $Choice = (Read-Host "Selection").Trim()

    switch ($Choice) {
        "Q" { break MenuLoop } # Successfully escapes the main menu loop directly!
        "1" {
            # --- Folder / Category Explorer ---
            $FolderMode = $true
            while ($FolderMode) {
                Clear-Host
                Write-Host "--- Folders (Categories) ---" -ForegroundColor Yellow
                
                $Categories = @(Get-AllFolders)
                
                if ($Categories.Count -eq 0) { Write-Host "  (No folders found. Add a tool or run scan.)" }
                else {
                    for ($i=0; $i -lt $Categories.Count; $i++) { Write-Host "  $($i+1). $($Categories[$i])" }
                }
                Write-Host "`nOptions: Folder Number to Open | [N]ew Folder | [R]ename Folder | [B]ack"
                $CatChoice = (Read-Host "Selection").Trim()
                if ($CatChoice.ToUpper() -eq 'B') { $FolderMode = $false; continue }
                
                # New Folder Creation Option
                if ($CatChoice.ToUpper() -eq 'N') {
                    $NewFolder = (Read-Host "Enter name for the new folder").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($NewFolder)) {
                        New-PhysicalFolder -FolderName $NewFolder
                        Write-Host "[+] Folder '$NewFolder' created successfully on disk!" -ForegroundColor Green
                        Start-Sleep 1
                    }
                    continue
                }

                # Rename Folder Suite (with Rename & Merge mechanics)
                if ($CatChoice.ToUpper() -eq 'R') {
                    if ($Categories.Count -eq 0) { continue }
                    Write-Host "`nSelect folder number to Rename/Merge:"
                    for ($i=0; $i -lt $Categories.Count; $i++) { Write-Host "  $($i+1). $($Categories[$i])" }
                    $RenIdxInput = Read-Host "Folder Number"
                    if ($RenIdxInput -match '^\d+$' -and [int]$RenIdxInput -gt 0 -and [int]$RenIdxInput -le $Categories.Count) {
                        $OldName = $Categories[[int]$RenIdxInput - 1]
                        $NewName = (Read-Host "Enter new name for folder '$OldName'").Trim()
                        if ([string]::IsNullOrWhiteSpace($NewName)) { continue }
                        
                        $DestExists = $GlobalConfig.Scripts | Where-Object { $_.Category -eq $NewName }
                        if ($DestExists) {
                            Write-Host "`n[Conflict] A folder named '$NewName' already exists!" -ForegroundColor Yellow
                            Write-Host "  1. Choose a different unique folder name"
                            Write-Host "  2. Merge this folder and all its contents inside '$NewName'"
                            $ActionChoice = Read-Host "Select option (1-2)"
                            
                            if ($ActionChoice -eq '2') {
                                # Merge folders loop
                                $OldScripts = @($GlobalConfig.Scripts | Where-Object { $_.Category -eq $OldName })
                                foreach ($S in $OldScripts) {
                                    $Collision = $GlobalConfig.Scripts | Where-Object { $_.Category -eq $NewName -and $_.Name -eq $S.Name }
                                    if ($Collision) {
                                        $Resolved = Resolve-ScriptCollision -IncomingScript $S -ExistingScript $Collision -Folder $NewName
                                        if ($null -ne $Resolved) {
                                            Move-PhysicalScriptFile -Script $Resolved -NewCategory $NewName
                                            $Resolved.Category = $NewName
                                            if ($Resolved.ID -eq $S.ID) {
                                                $GlobalConfig.Scripts += $Resolved
                                            }
                                        } else {
                                            $GlobalConfig.Scripts = @($GlobalConfig.Scripts | Where-Object { $_.ID -ne $S.ID })
                                        }
                                    } else {
                                        Move-PhysicalScriptFile -Script $S -NewCategory $NewName
                                        $S.Category = $NewName
                                    }
                                }
                                $OldPhysDir = Join-Path $DefaultScriptDir $OldName
                                if (Test-Path $OldPhysDir) { Remove-Item -Path $OldPhysDir -Recurse -Force -ErrorAction SilentlyContinue }
                                Save-Catalog
                                Write-Host "[+] Folders merged successfully!" -ForegroundColor Green
                                Start-Sleep 2
                            }
                        } else {
                            # Standard Directory Rename
                            $OldPhysDir = Join-Path $DefaultScriptDir $OldName
                            $NewPhysDir = Join-Path $DefaultScriptDir $NewName
                            $RenameSuccess = $true
                            
                            if (Test-Path $OldPhysDir -PathType Container) {
                                try {
                                    Rename-Item -Path $OldPhysDir -NewName $NewName -Force -ErrorAction Stop
                                } catch {
                                    $RenameSuccess = $false
                                    Write-Host "`n[-] Failed to rename physical folder. Make sure no files are open." -ForegroundColor Red
                                    Start-Sleep 2
                                }
                            } else {
                                # If missing physically, self-heal and create the new renamed directory
                                New-Item -ItemType Directory -Path $NewPhysDir -Force | Out-Null
                            }
                            
                            if ($RenameSuccess) {
                                $OldScripts = @($GlobalConfig.Scripts | Where-Object { $_.Category -eq $OldName })
                                foreach ($S in $OldScripts) {
                                    $S.Category = $NewName
                                    # Updated to use regex escaping to safely change paths
                                    $S.LocalPath = $S.LocalPath -replace "^src\\$([regex]::Escape($OldName))\\", "src\\$($NewName)\\"
                                    
                                    # Dynamically update paths for all listed companion/dependency files
                                    if ($null -ne $S.AdditionalFiles) {
                                        $NewAddFiles = @()
                                        foreach ($File in $S.AdditionalFiles) {
                                            $NewAddFiles += $File -replace "^src\\$([regex]::Escape($OldName))\\", "src\\$($NewName)\\"
                                        }
                                        $S.AdditionalFiles = $NewAddFiles
                                    }
                                }
                                Save-Catalog
                                Write-Host "[+] Folder successfully renamed." -ForegroundColor Green
                                Start-Sleep 1
                            }
                        }
                    }
                    continue
                }
                
                # Enter Category Loop
                if ($CatChoice -match '^\d+$' -and [int]$CatChoice -gt 0 -and [int]$CatChoice -le $Categories.Count) {
                    $SelectedCat = $Categories[[int]$CatChoice - 1]
                    $SearchTerm = ""
                    
                    $InFolder = $true
                    while ($InFolder) {
                        Clear-Host
                        Write-Host "--- Folder: $SelectedCat ---" -ForegroundColor Yellow
                        if ($SearchTerm) { Write-Host "Active Search: '$SearchTerm' (Type '/reset' to clear)" -ForegroundColor Cyan }
                        
                        $Scripts = @($GlobalConfig.Scripts | Where-Object { $_.Category -eq $SelectedCat })
                        if ($SearchTerm) {
                            $Scripts = @($Scripts | Where-Object { 
                                $_.Name -match $SearchTerm -or 
                                $_.Description -match $SearchTerm -or 
                                ($_.Tags -join " ") -match $SearchTerm 
                            })
                        }
                        
                        if ($Scripts.Count -eq 0) {
                            Write-Host "  No scripts found matching parameters."
                        } else {
                            for ($i=0; $i -lt $Scripts.Count; $i++) { 
                                Write-Host "  $($i+1). $($Scripts[$i].Name)" 
                            }
                        }
                        
                        Write-Host "`nCommands: <Number> to Select | /s <keyword> to Search | B to Back"
                        $Input = (Read-Host "Command").Trim()
                        if ($Input.ToUpper() -eq 'B') { $InFolder = $false; continue }
                        if ($Input -like "/s *") { $SearchTerm = $Input.Substring(3).Trim(); continue }
                        if ($Input -eq "/reset") { $SearchTerm = ""; continue }
                        
                        if ($Input -match '^\d+$') {
                            $Idx = [int]$Input - 1
                            if ($Idx -ge 0 -and $Idx -lt $Scripts.Count) {
                                $TempScript = $Scripts[$Idx]
                                $Script = $GlobalConfig.Scripts.Where({ $_.ID -eq $TempScript.ID }, 'First')[0]
                                
                                if ($Script) {
                                    $SubAction = ""
                                    while ($SubAction.ToUpper() -ne 'B') {
                                        Clear-Host
                                        Write-Host "Details: $($Script.Name)" -ForegroundColor Yellow
                                        if (-not [string]::IsNullOrWhiteSpace($Script.Description)) {
                                            Write-Host "Description: $($Script.Description)" -ForegroundColor DarkGray
                                        }
                                        Write-Host "Category: $($Script.Category)"
                                        Write-Host "Tags: " -NoNewline; Write-Host ($Script.Tags -join ", ") -ForegroundColor Cyan
                                        if ($Script.AdditionalFiles.Count -gt 0) {
                                            Write-Host "Dependencies: " -NoNewline; Write-Host ($Script.AdditionalFiles -join ", ") -ForegroundColor DarkYellow
                                        }
                                        Write-Host "`n1. Run Script`n2. Add Tag`n3. Remove Tag`n4. Edit Metadata`n5. Move to Another Folder`nB. Back"
                                        $SubAction = Read-Host "Action"
                                        
                                        if ($SubAction -eq '1') {
                                            $ArgsInput = Read-Host "Enter any arguments for the script (Leave blank for none)"
                                            Invoke-Script -Script $Script -Arguments $ArgsInput
                                        }
                                        elseif ($SubAction -eq '2') {
                                            $NewTag = (Read-Host "Enter new tag").Trim()
                                            if (-not [string]::IsNullOrWhiteSpace($NewTag)) {
                                                if (-not ($Script.Tags -contains $NewTag)) { 
                                                    $Script.Tags = @($Script.Tags) + $NewTag
                                                    Save-Catalog
                                                }
                                            }
                                        }
                                        elseif ($SubAction -eq '3') {
                                            $RemTag = (Read-Host "Enter tag to remove").Trim()
                                            if (-not [string]::IsNullOrWhiteSpace($RemTag)) {
                                                $Script.Tags = @(@($Script.Tags) | Where-Object { $_ -ne $RemTag })
                                                Save-Catalog
                                            }
                                        }
                                        elseif ($SubAction -eq '4') {
                                            Clear-Host
                                            Write-Host "--- Edit Metadata: $($Script.Name) ---" -ForegroundColor Yellow
                                            
                                            $NewName = Read-Host "New Name (Current: $($Script.Name)) [Enter to skip]"
                                            if (-not [string]::IsNullOrWhiteSpace($NewName)) { $Script.Name = $NewName }
                                            
                                            $NewDesc = Read-Host "New Description (Current: $($Script.Description)) [Enter to skip]"
                                            if (-not [string]::IsNullOrWhiteSpace($NewDesc)) { $Script.Description = $NewDesc }
                                            
                                            $NewPath = Read-Host "New Local Path (Current: $($Script.LocalPath)) [Enter to skip]"
                                            if (-not [string]::IsNullOrWhiteSpace($NewPath)) { 
                                                $Script.LocalPath = Get-RelativePath -Path $NewPath 
                                            }
                                            
                                            Save-Catalog
                                            Write-Host "[+] Metadata successfully updated!" -ForegroundColor Green
                                            Start-Sleep 1
                                        }
                                        elseif ($SubAction -eq '5') {
                                            # --- Move Script Logic ---
                                            Clear-Host
                                            Write-Host "--- Move Script to Another Folder ---" -ForegroundColor Yellow
                                            $AvailCats = @(Get-AllFolders)
                                            Write-Host "Select Target Folder:"
                                            for ($i=0; $i -lt $AvailCats.Count; $i++) { Write-Host "  $($i+1). $($AvailCats[$i])" }
                                            Write-Host "  N. New Folder"
                                            
                                            $MoveChoice = Read-Host "Selection"
                                            $TargetCat = ""
                                            if ($MoveChoice.ToUpper() -eq 'N') {
                                                $TargetCat = (Read-Host "Enter New Folder Name").Trim()
                                                New-PhysicalFolder -FolderName $TargetCat
                                            } elseif ($MoveChoice -match '^\d+$' -and [int]$MoveChoice -gt 0 -and [int]$MoveChoice -le $AvailCats.Count) {
                                                $TargetCat = $AvailCats[[int]$MoveChoice - 1]
                                            }
                                            
                                            if (-not [string]::IsNullOrWhiteSpace($TargetCat)) {
                                                # Check collision inside Target folder
                                                $Collision = $GlobalConfig.Scripts | Where-Object { $_.Category -eq $TargetCat -and $_.Name -eq $Script.Name }
                                                if ($Collision) {
                                                    $Resolved = Resolve-ScriptCollision -IncomingScript $Script -ExistingScript $Collision -Folder $TargetCat
                                                    if ($null -ne $Resolved) {
                                                        Move-PhysicalScriptFile -Script $Resolved -NewCategory $TargetCat
                                                        $Resolved.Category = $TargetCat
                                                        if ($Resolved.ID -eq $Script.ID) {
                                                            Save-Catalog
                                                            Write-Host "[+] Moved script!" -ForegroundColor Green
                                                            $SubAction = 'B'
                                                        }
                                                    }
                                                } else {
                                                    Move-PhysicalScriptFile -Script $Script -NewCategory $TargetCat
                                                    $Script.Category = $TargetCat
                                                    Save-Catalog
                                                    Write-Host "[+] Script moved successfully!" -ForegroundColor Green
                                                    Start-Sleep 1
                                                    $SubAction = 'B'
                                                }
                                            }
                                        }
                                    }
                                }
                            } else {
                                Write-Host "[-] Invalid selection." -ForegroundColor Red
                                Start-Sleep 1
                            }
                        }
                    }
                }
            }
        }
        "2" {
            # --- Global Tag Manager ---
            $ManageTags = $true
            while($ManageTags) {
                Clear-Host
                Write-Host "--- Global Tag Manager ---" -ForegroundColor Yellow
                $AllTags = $GlobalConfig.Scripts.Tags | Sort-Object -Unique
                if ($AllTags.Count -eq 0) { Write-Host "  No tags found in the system." }
                else {
                    Write-Host "  Current Tags:"
                    foreach ($T in $AllTags) { Write-Host "  - $T" }
                }
                Write-Host "`nOptions: [A]dd New Tag | [U]pdate Name | [R]emove Tag | [B]ack"
                $Action = Read-Host "Action"
                
                if ($Action.ToUpper() -eq 'A') {
                    $NewTag = (Read-Host "Enter name for new tag").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($NewTag)) {
                        $Apply = Read-Host "Would you like to assign this tag to a script now? (Y/N)"
                        if ($Apply.ToUpper() -eq 'Y') {
                            Write-Host "`nAvailable Scripts:"
                            foreach ($S in $GlobalConfig.Scripts) { Write-Host "  $($S.ID). $($S.Name)" }
                            $SID = Read-Host "Enter Script ID to tag"
                            if ($SID -match '^\d+$') {
                                $Target = $GlobalConfig.Scripts.Where({ $_.ID -eq [int]$SID }, 'First')[0]
                                if ($Target) {
                                    if (-not ($Target.Tags -contains $NewTag)) { 
                                        $Target.Tags = @($Target.Tags) + $NewTag
                                        Save-Catalog
                                        Write-Host "[+] Tag '$NewTag' assigned to '$($Target.Name)'." -ForegroundColor Green
                                    } else {
                                        Write-Host "[!] Script already has this tag." -ForegroundColor Yellow
                                    }
                                } else {
                                    Write-Host "[-] Script ID not found." -ForegroundColor Red
                                }
                            } else {
                                Write-Host "[-] Invalid ID selection." -ForegroundColor Red
                            }
                            Start-Sleep 2
                        }
                    }
                }
                elseif ($Action.ToUpper() -eq 'U') {
                    $OldTag = (Read-Host "Enter existing tag name to rename").Trim()
                    if (-not $AllTags -contains $OldTag) { Write-Host "Tag '$OldTag' not found."; Start-Sleep 1; continue }
                    $NewTag = (Read-Host "Enter new tag name").Trim()
                    
                    if (-not [string]::IsNullOrWhiteSpace($NewTag)) {
                        foreach ($S in $GlobalConfig.Scripts) {
                            if ($S.Tags -contains $OldTag) {
                                $S.Tags = @(@($S.Tags) | Where-Object { $_ -ne $OldTag }) + $NewTag
                            }
                        }
                        Save-Catalog
                        Write-Host "[+] Updated '$OldTag' -> '$NewTag' globally." -ForegroundColor Green
                        Start-Sleep 1
                    }
                }
                elseif ($Action.ToUpper() -eq 'R') {
                    $RemTag = (Read-Host "Enter tag to remove from all tools").Trim()
                    if (-not [string]::IsNullOrWhiteSpace($RemTag)) {
                        foreach ($S in $GlobalConfig.Scripts) {
                            $S.Tags = @(@($S.Tags) | Where-Object { $_ -ne $RemTag })
                        }
                        Save-Catalog
                        Write-Host "[+] Removed '$RemTag' from all tools." -ForegroundColor Green
                        Start-Sleep 1
                    }
                }
                elseif ($Action.ToUpper() -eq 'B') { $ManageTags = $false }
            }
        }
        "A" {
            # --- Register Tool Manually ---
            Clear-Host
            Write-Host "--- Register New Tool Manually ---" -ForegroundColor Yellow
            $Name = (Read-Host "Tool Name").Trim()
            $Desc = (Read-Host "Description").Trim()
            
            $Categories = @(Get-AllFolders)
            Write-Host "`nSelect a folder for this tool:"
            for ($i=0; $i -lt $Categories.Count; $i++) { Write-Host "  $($i+1). $($Categories[$i])" }
            Write-Host "  N. Create New Folder"
            
            $CatInput = Read-Host "Selection"
            $Cat = ""
            if ($CatInput.ToUpper() -eq 'N') { 
                $Cat = (Read-Host "Enter New Folder Name").Trim() 
                New-PhysicalFolder -FolderName $Cat
            }
            elseif ($CatInput -match '^\d+$' -and [int]$CatInput -gt 0 -and [int]$CatInput -le $Categories.Count) { $Cat = $Categories[[int]$CatInput - 1] }
            else { $Cat = "General" }
            
            $Path = (Read-Host "Local Path").Trim()
            
            $NewID = if ($GlobalConfig.Scripts.Count -gt 0) { ($GlobalConfig.Scripts | Measure-Object -Property ID -Maximum).Maximum + 1 } else { 1 }
            $NewScript = [PSCustomObject]@{
                ID              = $NewID
                Name            = $Name
                Category        = $Cat
                LocalPath       = Get-RelativePath -Path $Path
                Description     = $Desc
                Tags            = @()
                GitHubRawUrl    = ""
                AdditionalFiles = @()
            }

            # Check for duplicate names inside directory selection
            $Collision = $GlobalConfig.Scripts | Where-Object { $_.Category -eq $Cat -and $_.Name -eq $Name }
            if ($Collision) {
                $Resolved = Resolve-ScriptCollision -IncomingScript $NewScript -ExistingScript $Collision -Folder $Cat
                if ($null -ne $Resolved) {
                    $GlobalConfig.Scripts += $Resolved
                    Save-Catalog
                    Write-Host "[+] Tool successfully saved." -ForegroundColor Green
                }
            } else {
                $GlobalConfig.Scripts += $NewScript
                Save-Catalog
                Write-Host "[+] Tool '$Name' registered." -ForegroundColor Green
            }
            Start-Sleep 1
        }
        "G" {
            # --- GitHub Import Engine with Smart URL Converting & Dependencies ---
            Clear-Host
            Write-Host "--- GitHub Downloader & Import Suite ---" -ForegroundColor Yellow
            $RawUrlInput = (Read-Host "Enter GitHub Script URL").Trim()
            
            if (-not [string]::IsNullOrWhiteSpace($RawUrlInput)) {
                # Convert regular Browser links to Raw User Content endpoints
                $GithubUrl = $RawUrlInput
                if ($GithubUrl -match "^https?://github\.com/") {
                    $GithubUrl = $GithubUrl -replace "^(https?://)github\.com/", '$1raw.githubusercontent.com/'
                    $GithubUrl = $GithubUrl -replace "/blob/", "/"
                }
                
                $DefaultName = Split-Path $GithubUrl -Leaf
                $ScriptName = (Read-Host "Confirm / Edit script filename [$DefaultName]").Trim()
                if ([string]::IsNullOrWhiteSpace($ScriptName)) { $ScriptName = $DefaultName }
                
                $Categories = @(Get-AllFolders)
                Write-Host "`nSelect target folder for download:"
                for ($i=0; $i -lt $Categories.Count; $i++) { Write-Host "  $($i+1). $($Categories[$i])" }
                Write-Host "  N. New Folder"
                
                $FolderSelect = Read-Host "Selection"
                $TargetFolder = ""
                if ($FolderSelect.ToUpper() -eq 'N') {
                    $TargetFolder = (Read-Host "Enter New Folder Name").Trim()
                    New-PhysicalFolder -FolderName $TargetFolder
                } elseif ($FolderSelect -match '^\d+$' -and [int]$FolderSelect -gt 0 -and [int]$FolderSelect -le $Categories.Count) {
                    $TargetFolder = $Categories[[int]$FolderSelect - 1]
                } else {
                    $TargetFolder = "General"
                }

                $DepsList = (Read-Host "Enter additional files to pull from same branch (e.g. README.md, config.json) [Comma Separated]").Trim()
                $DepsArray = @()
                if (-not [string]::IsNullOrWhiteSpace($DepsList)) {
                    $DepsArray = @($DepsList.Split(',') | ForEach-Object { $_.Trim() })
                }
                
                $WriteDir = Join-Path $DefaultScriptDir $TargetFolder
                if (-not (Test-Path $WriteDir)) { New-Item -ItemType Directory -Path $WriteDir -Force | Out-Null }
                
                $TargetLocalPath = Join-Path $WriteDir $ScriptName
                
                try {
                    Write-Host "[*] Fetching raw script content..." -ForegroundColor Cyan
                    Invoke-WebRequest -Uri $GithubUrl -OutFile $TargetLocalPath -ErrorAction Stop
                    
                    $AdditionalFilesPhysical = @()
                    if ($DepsArray.Count -gt 0) {
                        $BaseTreeUrl = $GithubUrl.Substring(0, $GithubUrl.LastIndexOf('/') + 1)
                        foreach ($Dep in $DepsArray) {
                            $DepUrl = $BaseTreeUrl + $Dep
                            $DepLocalPath = Join-Path $WriteDir $Dep
                            Write-Host "[*] Fetching companion asset: $Dep..." -ForegroundColor Cyan
                            try {
                                Invoke-WebRequest -Uri $DepUrl -OutFile $DepLocalPath -ErrorAction Stop
                                $AdditionalFilesPhysical += Get-RelativePath -Path $DepLocalPath
                            } catch {
                                Write-Host "[!] Could not fetch dependency '$Dep': $_" -ForegroundColor Yellow
                            }
                        }
                    }
                    
                    $NewID = if ($GlobalConfig.Scripts.Count -gt 0) { ($GlobalConfig.Scripts | Measure-Object -Property ID -Maximum).Maximum + 1 } else { 1 }
                    $NewScript = [PSCustomObject]@{
                        ID              = $NewID
                        Name            = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
                        Category        = $TargetFolder
                        LocalPath       = Get-RelativePath -Path $TargetLocalPath
                        Description     = "Downloaded from GitHub source repository."
                        Tags            = @("GitHub")
                        GitHubRawUrl    = $GithubUrl
                        AdditionalFiles = $AdditionalFilesPhysical
                    }
                    
                    # Run Collision Detection Pipeline
                    $Collision = $GlobalConfig.Scripts | Where-Object { $_.Category -eq $TargetFolder -and $_.Name -eq $NewScript.Name }
                    if ($Collision) {
                        $Resolved = Resolve-ScriptCollision -IncomingScript $NewScript -ExistingScript $Collision -Folder $TargetFolder
                        if ($null -ne $Resolved) {
                            $GlobalConfig.Scripts += $Resolved
                            Save-Catalog
                            Write-Host "[+] GitHub tool successfully integrated." -ForegroundColor Green
                        }
                    } else {
                        $GlobalConfig.Scripts += $NewScript
                        Save-Catalog
                        Write-Host "[+] GitHub tool imported successfully!" -ForegroundColor Green
                    }
                } catch {
                    Write-Host "[-] GitHub Core Download Failed: $_" -ForegroundColor Red
                }
            }
            Read-Host "Press Enter to return..."
        }
        "I" {
            # --- Import Nested Folder Manifest ---
            Clear-Host
            Write-Host "--- Import Folder-Centric Manifest ---" -ForegroundColor Yellow
            $ManifestPath = Read-Host "Enter path to JSON manifest file"
            
            if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
                if (-not [System.IO.Path]::IsPathRooted($ManifestPath)) {
                    $ManifestPath = Join-Path $PSScriptRoot $ManifestPath
                }
                $ManifestPath = [System.IO.Path]::GetFullPath($ManifestPath)
                
                if (Test-Path $ManifestPath -PathType Leaf) {
                    try {
                        $RawJson = Get-Content -Raw -Path $ManifestPath -ErrorAction Stop
                        $ImportData = ConvertFrom-Json $RawJson -ErrorAction Stop
                        
                        $ImportCount = 0
                        if ($null -ne $ImportData.Folders) {
                            foreach ($Folder in $ImportData.Folders) {
                                $Cat = $Folder.Name
                                New-PhysicalFolder -FolderName $Cat  # Dynamic self-heal folder creation on import
                                
                                foreach ($Item in $Folder.Scripts) {
                                    $NameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name)
                                    
                                    # Setup incoming asset model
                                    $NewID = if ($GlobalConfig.Scripts.Count -gt 0) { ($GlobalConfig.Scripts | Measure-Object -Property ID -Maximum).Maximum + 1 } else { 1 }
                                    $ScriptToAdd = [PSCustomObject]@{
                                        ID              = $NewID
                                        Name            = if ($null -ne $Item.Name) { $Item.Name } else { "Unnamed Script" }
                                        Category        = $Cat
                                        LocalPath       = if ($null -ne $Item.LocalPath) { Get-RelativePath -Path $Item.LocalPath } else { "" }
                                        Description     = if ($null -ne $Item.Description) { $Item.Description } else { "" }
                                        Tags            = if ($null -eq $Item.Tags) { @() } else { @($Item.Tags) }
                                        GitHubRawUrl    = if ($null -ne $Item.GitHubRawUrl) { $Item.GitHubRawUrl } else { "" }
                                        AdditionalFiles = if ($null -eq $Item.AdditionalFiles) { @() } else { @($Item.AdditionalFiles) }
                                    }
                                    
                                    $Exists = $GlobalConfig.Scripts | Where-Object { $_.Name -eq $ScriptToAdd.Name -and $_.Category -eq $Cat }
                                    if ($Exists) {
                                        $Resolved = Resolve-ScriptCollision -IncomingScript $ScriptToAdd -ExistingScript $Exists -Folder $Cat
                                        if ($null -ne $Resolved) {
                                            $GlobalConfig.Scripts += $Resolved
                                            $ImportCount++
                                        }
                                    } else {
                                        $GlobalConfig.Scripts += $ScriptToAdd
                                        $ImportCount++
                                    }
                                }
                            }
                        }
                        if ($ImportCount -gt 0) {
                            Save-Catalog
                            Write-Host "[+] Successfully processed and synchronized $ImportCount tools!" -ForegroundColor Green
                        } else {
                            Write-Host "[!] No new tools integrated." -ForegroundColor Yellow
                        }
                    }
                    catch {
                        Write-Host "[-] Failed to parse nested schema manifest: $_" -ForegroundColor Red
                    }
                } else {
                    Write-Host "[-] Manifest file not found." -ForegroundColor Red
                }
            }
            Read-Host "Press Enter to continue..."
        }
        "E" {
            # --- Export Nested Folder Manifest ---
            Clear-Host
            Write-Host "--- Export Folder-Centric Manifest ---" -ForegroundColor Yellow
            $DefaultExport = "toolkit_manifest_export.json"
            $ExportPath = Read-Host "Enter destination file path [Default: $DefaultExport]"
            if ([string]::IsNullOrWhiteSpace($ExportPath)) { $ExportPath = $DefaultExport }
            
            if (-not [System.IO.Path]::IsPathRooted($ExportPath)) {
                $ExportPath = Join-Path $PSScriptRoot $ExportPath
            }
            $ExportPath = [System.IO.Path]::GetFullPath($ExportPath)
            
            try {
                $ExportData = @{
                    Folders = @()
                }
                $Categories = @(Get-AllFolders)
                foreach ($Cat in $Categories) {
                    $FolderScripts = @($GlobalConfig.Scripts | Where-Object { $_.Category -eq $Cat })
                    $ScriptList = @()
                    foreach ($S in $FolderScripts) {
                        $ScriptList += [PSCustomObject]@{
                            Name            = $S.Name
                            LocalPath       = $S.LocalPath
                            Description     = $S.Description
                            Tags            = $S.Tags
                            GitHubRawUrl    = $S.GitHubRawUrl
                            AdditionalFiles = $S.AdditionalFiles
                        }
                    }
                    $ExportData.Folders += @{
                        Name    = $Cat
                        Scripts = $ScriptList
                    }
                }
                
                $RawJson = ConvertTo-Json $ExportData -Depth 5
                Set-Content -Path $ExportPath -Value $RawJson -Force
                Write-Host "[+] Manifest successfully exported to $ExportPath in folder structure layout!" -ForegroundColor Green
            } catch {
                Write-Host "[-] Export failed: $_" -ForegroundColor Red
            }
            Read-Host "Press Enter to continue..."
        }
        "R" {
            # --- Dedicated Remove Tool Menu ---
            $RemoveMode = $true
            while ($RemoveMode) {
                Clear-Host
                Write-Host "--- Remove Tool Menu ---" -ForegroundColor Red
                $Categories = @(Get-AllFolders)
                
                if ($Categories.Count -eq 0) {
                    Write-Host "  No scripts or folders exist to remove."
                    Read-Host "Press Enter..."
                    $RemoveMode = $false
                    continue
                }
                
                Write-Host "Select a folder to view tools for removal:"
                for ($i=0; $i -lt $Categories.Count; $i++) { Write-Host "  $($i+1). $($Categories[$i])" }
                Write-Host "`n  B. Back"
                
                $CatChoice = Read-Host "Selection"
                if ($CatChoice.ToUpper() -eq 'B') { $RemoveMode = $false; continue }
                
                if ($CatChoice -match '^\d+$' -and [int]$CatChoice -gt 0 -and [int]$CatChoice -le $Categories.Count) {
                    $SelectedCat = $Categories[[int]$CatChoice - 1]
                    
                    $InRemoveFolder = $true
                    while ($InRemoveFolder) {
                        Clear-Host
                        Write-Host "--- Remove Tool in Folder: $SelectedCat ---" -ForegroundColor Red
                        $Scripts = @($GlobalConfig.Scripts | Where-Object { $_.Category -eq $SelectedCat })
                        
                        if ($Scripts.Count -eq 0) {
                            Write-Host "  No tools left in this folder."
                            Read-Host "Press Enter..."
                            $InRemoveFolder = $false
                            continue
                        }
                        
                        for ($i=0; $i -lt $Scripts.Count; $i++) {
                            Write-Host "  $($i+1). $($Scripts[$i].Name)"
                        }
                        Write-Host "`nSelect relative number to REMOVE, or 'B' to Go Back:"
                        $Input = Read-Host "Selection"
                        
                        if ($Input.ToUpper() -eq 'B') { $InRemoveFolder = $false; continue }
                        
                        if ($Input -match '^\d+$' -and [int]$Input -gt 0 -and [int]$Input -le $Scripts.Count) {
                            $Idx = [int]$Input - 1
                            $ScriptToRemove = $Scripts[$Idx]
                            
                            $Confirm = Read-Host "Are you sure you want to completely remove '$($ScriptToRemove.Name)'? (Y/N)"
                            if ($Confirm.ToUpper() -eq 'Y') {
                                $GlobalConfig.Scripts = @($GlobalConfig.Scripts | Where-Object { $_.ID -ne $ScriptToRemove.ID })
                                Save-Catalog
                                Write-Host "[-] Tool successfully removed." -ForegroundColor Green
                                Start-Sleep 1
                            }
                        }
                    }
                }
            }
        }
        "S" {
            # --- Settings Menu ---
            $InSettings = $true
            while ($InSettings) {
                Clear-Host
                Write-Host "--- Settings & Configuration ---" -ForegroundColor Yellow
                Write-Host "  Current Execution Mode: " -NoNewline; Write-Host "$($GlobalConfig.Settings.ExecutionMode)" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "  1. Toggle Execution Mode (ClearSession / NewWindow)"
                Write-Host "  2. Force Run Manual Directory Scan"
                Write-Host "  B. Return to Main Menu"
                Write-Host "--------------------------------------------------" -ForegroundColor Yellow
                
                $SettingAction = (Read-Host "Selection").Trim()
                if ($SettingAction.ToUpper() -eq 'B') { $InSettings = $false }
                elseif ($SettingAction -eq '1') {
                    if ($GlobalConfig.Settings.ExecutionMode -eq "ClearSession") {
                        $GlobalConfig.Settings.ExecutionMode = "NewWindow"
                    } else {
                        $GlobalConfig.Settings.ExecutionMode = "ClearSession"
                    }
                    Save-Catalog
                }
                elseif ($SettingAction -eq '2') {
                    Sync-LocalFolder
                    Write-Host "[+] Directory scan completed." -ForegroundColor Green
                    Start-Sleep 1
                }
            }
        }
    }
} while ($true)