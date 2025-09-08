
; CleanupDevCache.ahk  —  AutoHotkey v2
; A safe, GUI-based dev cache cleaner for Windows 11
; - Shows a preview (paths + sizes) first
; - Deletes only after user confirmation
; - Respects config.ini for roots, patterns, exclusions, and optional Windows/global caches
; Tested with AutoHotkey v2.x

; --- Self-elevate to Admin if not already running as Admin ---
if not A_IsAdmin {
    try {
        FullCommand := DllCall("GetCommandLine", "Str")
        if RegExMatch(FullCommand, " /restart(?:\s|$)", &m) {
            MsgBox "Failed to elevate to admin. Please run as administrator manually.", "Admin Rights Required", "Icon!"
            ExitApp
        }
        Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
        ExitApp
    } catch {
        MsgBox "Failed to elevate to admin. Please run as administrator manually.", "Admin Rights Required", "Icon!"
        ExitApp
    }
}

#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent
ProcessSetPriority "High"

; Cleanup on exit
OnExit CleanupOnExit

; --- Tray Menu ---
A_TrayMenu.Delete()
A_TrayMenu.Add("Exit", (*) => ExitApp())

; ---------------------------
; ---- Config & Defaults ----
; ---------------------------
; Constants
MAX_DEPTH_DEFAULT := 8
MAX_FILES_SIZE_CALC := 100000
TIMEOUT_SIZE_CALC_MS := 30000
DEFAULT_CONFIRM_DELETE := true
DEFAULT_INCLUDE_WINDOWS := true
DEFAULT_INCLUDE_GLOBAL := true
MAX_LISTVIEW_ITEMS := 5000  ; Limit for ListView to prevent bloat

global AppTitle := "Dev Cache Cleaner"
global IniFile  := A_ScriptDir "\cleanup.ini"
global MaxDepth := MAX_DEPTH_DEFAULT
global IncludeWindowsCleanup := DEFAULT_INCLUDE_WINDOWS
global IncludeGlobalCaches   := DEFAULT_INCLUDE_GLOBAL
global ConfirmBeforeDelete   := DEFAULT_CONFIRM_DELETE
global LogFile := A_ScriptDir "\cleanup.log"
global PreserveNames := []

; Collections read from INI
global RootPaths := []
global AlwaysDeletePaths := []
global MarkerFiles := []
global CacheDirPatterns := []
global ExcludeDirSegments := []
global ExcludeExactPaths := []
global WindowsTempDirs := []
global GlobalCachePaths := []
global SystemFilePatterns := []
global SkipDirs := []





; UI globals
global LV, TotalLabel, StatusBar, DeleteBtn, RefreshBtn, OpenBtn, SelectAllChk, ProgressBar
global Items := [] ; array of maps: {type, path, size}

; ---------------------------
; ------------ Main ---------
; ---------------------------
Init()
BuildGui()
ScanAndPopulate()

return

; ---------------------------
; ---------- Init -----------
; ---------------------------
Init() {
    global
    if !FileExist(IniFile) {
        MsgBox "Config not found. Creating default ini at:`n" IniFile, AppTitle, "Iconi"
        WriteDefaultIni(IniFile)
    }

    ReadConfig(IniFile)
    try FileDelete(LogFile)
}

WriteDefaultIni(path) {
    FileDelete(path)

    FileAppend(
"[" "General" "]`n"
"ConfirmBeforeDelete=1`n"
"MaxDepth=8`n"
"IncludeWindowsCleanup=1`n"
"IncludeGlobalCaches=1`n"
"LogFile=" A_ScriptDir "\cleanup.log`n"
"`n[" "Roots" "]`n"
"; Separate with | or newline`n"
"Paths=%USERPROFILE%\\Projects|D:\\Workspaces`n"
"`n[" "AlwaysDelete" "]`n"
"Paths=%USERPROFILE%\\Downloads\\_temp`n"
"`n[" "Markers" "]`n"
"Files=.git|package.json|composer.json|pyproject.toml|requirements.txt|Pipfile|Gemfile|go.mod|Cargo.toml|build.gradle|pom.xml|mix.exs|Makefile`n"
"`n[" "Patterns" "]`n"
"; Relative cache dirs to delete when a marker exists in a parent project folder`n"
"CacheDirs=node_modules\\.cache|.yarn\\cache|.parcel-cache|__pycache__|storage\\framework\\cache|var\\cache|.cache|.gradle\\caches|.m2\\repository\\.cache|.pytest_cache|.ruff_cache|.tox|.venv\\Lib\\site-packages\\*.dist-info\\direct_url.json|.nuget\\v3-cache|.pnpm-store|.vite\\cache|.next\\cache|.nuxt\\cache|.webpack\\cache|.rsbuild-cache|target\\.cache|gradle\\daemon\\*.log`n"
"`n[" "Excludes" "]`n"
"DirSegments=bootstrap\\cache|dist|build|.next\\server|.nuxt\\server|obj|bin`n"
"ExactPaths=`n"
"`n[" "WindowsCleanup" "]`n"
"TempDirs=%TEMP%|C:\\Windows\\Temp|%LOCALAPPDATA%\\Temp`n"
"`n[" "GlobalCaches" "]`n"
"; Global caches outside projects (safe to clear)`n"
"Paths=%USERPROFILE%\\AppData\\Local\\npm-cache|%LOCALAPPDATA%\\Yarn\\Cache|%LOCALAPPDATA%\\pnpm-store|%USERPROFILE%\\AppData\\Local\\pip\\Cache|%APPDATA%\\pypoetry\\Cache|%USERPROFILE%\\.cache\\pip|%USERPROFILE%\\.gradle\\caches|%USERPROFILE%\\.m2\\repository\\.cache|%LOCALAPPDATA%\\NuGet\\v3-cache|%USERPROFILE%\\.cargo\\registry\\cache|%USERPROFILE%\\go\\pkg\\mod\\cache|%LOCALAPPDATA%\\Google\\Chrome\\User Data\\Default\\Code Cache`n"
"`n[" "SkipDirs" "]`n"
"; Directories to skip during project scanning for speed`n"
"Dirs=node_modules,.git,vendor,.venv,.next,.nuxt,dist,build,obj,bin,target,.gradle`n"
, path)
}

ReadConfig(path) {
    global MaxDepth, PreserveNames, IncludeWindowsCleanup, IncludeGlobalCaches, ConfirmBeforeDelete, LogFile
    global RootPaths, AlwaysDeletePaths, MarkerFiles, CacheDirPatterns, ExcludeDirSegments, ExcludeExactPaths, WindowsTempDirs, GlobalCachePaths, SystemFilePatterns

    ; General
    ConfirmBeforeDelete := IniRead(path, "General", "ConfirmBeforeDelete", DEFAULT_CONFIRM_DELETE) = 1
    MaxDepth := Integer(IniRead(path, "General", "MaxDepth", MAX_DEPTH_DEFAULT))
    IncludeWindowsCleanup := IniRead(path, "General", "IncludeWindowsCleanup", DEFAULT_INCLUDE_WINDOWS) = 1
    IncludeGlobalCaches   := IniRead(path, "General", "IncludeGlobalCaches", DEFAULT_INCLUDE_GLOBAL) = 1
    LogFile := IniRead(path, "General", "LogFile", A_ScriptDir "\cleanup.log")

    ; Lists
    RootPaths := ExpandList(IniRead(path, "Roots", "Paths", ""))
    AlwaysDeletePaths := ExpandList(IniRead(path, "AlwaysDelete", "Paths", ""))
    MarkerFiles := SplitList(IniRead(path, "Markers", "Files", ""))
    CacheDirPatterns := SplitList(IniRead(path, "Patterns", "CacheDirs", ""))
    ExcludeDirSegments := SplitList(IniRead(path, "Excludes", "DirSegments", ""))
    ExcludeExactPaths := ExpandList(IniRead(path, "Excludes", "ExactPaths", ""))
    WindowsTempDirs := ExpandList(IniRead(path, "WindowsCleanup", "TempDirs", ""))
    GlobalCachePaths := ExpandList(IniRead(path, "GlobalCaches", "Paths", ""))
    SystemFilePatterns := SplitList(IniRead(path, "SystemPatterns", "Patterns", ""))
    SkipDirs := SplitList(IniRead(path, "SkipDirs", "Dirs", "node_modules,.git,vendor,.venv,.next,.nuxt,dist,build,obj,bin,target,.gradle"))



	; normal INI read first
	PreserveNamesRaw := IniRead(path, "Preserve", "Names", "")
	Log("[CFG] IniRead Preserve/Names raw='" PreserveNamesRaw "'")

	; if blank, try manual case-insensitive parse of the INI file
	if (Trim(PreserveNamesRaw) = "") {
		try {
			rawIni := FileRead(path, "UTF-8")
			; find a [Preserve] section (case-insensitive, allow spaces)
			if RegExMatch(rawIni, "mi)^\[\s*preserve\s*\]\s*(.*?)(?=^\s*\[|\z)", &sec) {
				secText := sec[1]
				if RegExMatch(secText, "mi)^\s*names\s*=\s*(.+)$", &nm) {
					PreserveNamesRaw := nm[1]
					Log("[CFG] Manual parse Names='" PreserveNamesRaw "'")
				} else {
					Log("[CFG] Manual parse: Names not found in [Preserve]")
				}
			} else {
				Log("[CFG] Manual parse: [Preserve] section not found")
			}
		} catch Error as e {
			Log("[CFG] Manual parse error: " e.Message)
		}
	}

	; Split into an Array (| , ; or newline)
	for p in StrSplit(PreserveNamesRaw, ["|","`n","`r",",",";"]) {
		p := Trim(p)
		if (p != "")
			PreserveNames.Push(p)
	}

	Log("[CFG] PreserveNames count=" PreserveNames.Length)
}

SplitList(str) {
    ; Accept | or newline/CRLF delimiters
    arr := []
    for part in StrSplit(str, ["|","`n","`r"]) {
        p := Trim(part)
        if (p != "")
            arr.Push(p)
    }
    return arr
}

ExpandEnv(path) {
    ; Custom environment variable expansion to work around issues with built-in functions in some environments.
    if !InStr(path, "%")
        return path

    out := ""
    i := 1
    while i <= StrLen(path) {
        if SubStr(path, i, 1) = "%" {
            j := InStr(path, "%", false, i+1)
            if j {
                var := SubStr(path, i+1, j-i-1)
                val := ""
                varLower := StrLower(var)

                ; Handle special cases first
                if (varLower = "systemdrive")
                    val := SubStr(A_WinDir, 1, 2)
                else if (varLower = "cd")
                    val := A_WorkingDir
                else
                    val := EnvGet(var) ; Try standard environment variables

                if (val = "")
                    val := "%" var "%" ; If still not found, leave it as is

                out .= val
                i := j + 1
                continue
            }
        }
        out .= SubStr(path, i, 1)
        i++
    }
    return out
}

ExpandList(str) {
    arr := SplitList(str)
    out := []
    for p in arr {
        out.Push(ExpandEnv(p))
    }
    return out
}

; ---------------------------
; ----------- GUI -----------
; ---------------------------
BuildGui() {
    global LV, TotalLabel, StatusBar, DeleteBtn, RefreshBtn, OpenBtn, SelectAllChk, ProgressBar

    GuiTitle := AppTitle
    myGui := Gui("+Resize -MaximizeBox", GuiTitle)
    myGui.MarginX := 10, myGui.MarginY := 10

	RefreshBtn := myGui.Add("Button", "x10 y10", "Refresh")
	RefreshBtn.GetPos(&rx, &ry, &rw, &rh)
    RefreshBtn.OnEvent("Click", ScanAndPopulate)

	DeleteBtn  := myGui.Add("Button", "x+10 yp Default", "Delete Selected…")
	DeleteBtn.GetPos(&dx, &dy, &dw, &dh)
    DeleteBtn.OnEvent("Click", DoDeleteSelected)

	OpenBtn := myGui.Add("Button", "x+10 yp", "Open Config")
	OpenBtn.OnEvent("Click", (*) => Run(A_ComSpec ' /c start "" "' IniFile '"'))

    myGui.SetFont("s12 cBlue Bold")
    TotalLabel := myGui.Add("Text", "x10 y+10 w300", "Recoverable: Calculating…")
    myGui.SetFont()

    ProgressBar := myGui.Add("Progress", "x10 y+5 w300 h20", 0)

    SelectAllChk := myGui.Add("Checkbox", "x10 y+5", "Select All")
    SelectAllChk.Value := true
    SelectAllChk.OnEvent("Click", (*) => (SelectAllChk.Value ? CheckAllItems() : UncheckAllItems()))

    myGui.SetFont("s10")  ; bigger list font

    LV := myGui.Add("ListView", "x10 y+5 w1050 r30 Grid Checked")
    myGui.SetFont()       ; reset to default for later controls

	LV.InsertCol(1, "", "Type")
	LV.InsertCol(2, "", "Path")
	LV.InsertCol(3, "", "Size")
	LV.InsertCol(4, "", "Bytes")   ; hidden numeric sort key
	LV.ModifyCol(4, "Float")     ; <- numeric sort
	LV.ModifyCol(4, 0)             ; keep hidden

    LV.ModifyCol(1, 180), LV.ModifyCol(2, 760), LV.ModifyCol(3, 100)
    LV.OnEvent("Click", (ctrl, row) => (row ? (Items[row]["selected"] := (ctrl.GetNext(row, "C") == row), UpdateTotals()) : 0))

    StatusBar := myGui.Add("StatusBar")
    myGui.OnEvent("Size", OnResize)

    myGui.OnEvent("Close", (*) => ExitApp())
    myGui.Show("w1100 h700 Center")
}

SetScanBusy(flag) {
    global RefreshBtn, DeleteBtn, OpenBtn, LV, SelectAllChk
    ; Disable everything except Exit while scanning
    for ctrl in [RefreshBtn, DeleteBtn, OpenBtn, LV, SelectAllChk] {
        try ctrl.Enabled := !flag
    }
    ; Exit stays enabled
}

SetUIBusy(flag) {
    global RefreshBtn, DeleteBtn, OpenBtn, LV, StatusBar, SelectAllChk
    for ctrl in [RefreshBtn, DeleteBtn, OpenBtn, LV, SelectAllChk] {
        try ctrl.Enabled := !flag
    }
    SB(flag ? "Deleting… please wait." : "Ready.")
}

OnResize(gui, minMax, width, height) {
    global LV, TotalLabel, RefreshBtn, DeleteBtn, OpenBtn, StatusBar, SelectAllChk, ProgressBar

    if (minMax = -1) ; minimized
        return

	RefreshBtn.Move(10, 10)
	RefreshBtn.GetPos(&rx, &ry, &rw, &rh)

	DeleteBtn.Move(rx + rw + 10, ry)
	DeleteBtn.GetPos(&dx, &dy, &dw, &dh)

	OpenBtn.Move(dx + dw + 10, ry)
	OpenBtn.GetPos(&ox, &oy, &ow, &oh)

	TotalLabel.Move(10 + ((width - 20 - 200) // 2), oy + oh + 10, 200)
	TotalLabel.GetPos(&tx, &ty, &tw, &th)

    SelectAllChk.Move(10, ty + th + 2)

 	LV.Move(10, ty + th + 22, width - 20, height - (ty + th + 22) - 22)
 	ProgressBar.Move((width - 300) / 2, (height - 20) / 2, 300, 20)
 	StatusBar.Move(, height - 22, width, 22)

}

AddItem(type, path, size) {
    global Items, SeenPaths
    p := NormalizePath(path)
    key := StrLower(p)
    if SeenPaths.Has(key)
        return
    if !FileExist(p)
        return
    if size == 0  ; Don't add items with zero size (e.g., empty dirs)
        return
    SeenPaths[key] := true
    Items.Push(Map("type", type, "path", p, "size", size))
}

; ---------------------------
; ---- Scanning & Sizes -----
; ---------------------------
ScanAndPopulate(*) {
    global Items, LV, SeenPaths, ProgressBar
    SetScanBusy(true)
    scanStart := A_TickCount
    Log("[SCAN] Starting scan at " A_Now)
    try {
        Items := []
        SeenPaths := Map()
        LV.Delete()
        ProgressBar.Visible := true
        ProgressBar.Value := 0
        SB("Scanning… this may take a bit on big folders.")

        AddAlwaysDelete()
        ProgressBar.Value := 20
        AddWindowsCleanup()
        ProgressBar.Value := 40
        AddGlobalCaches()
        ProgressBar.Value := 60
        AddSystemPatterns()
        ProgressBar.Value := 80
        AddProjectCaches()
        ProgressBar.Value := 100

        PopulateListView()
        CheckAllItems()
        SelectAllChk.Value := true
        ProgressBar.Value := 100
        ProgressBar.Visible := false
        scanEnd := A_TickCount
        scanTime := scanEnd - scanStart
        Log("[SCAN] Scan completed in " scanTime " ms, found " Items.Length " items")
        SB("Ready.")
    } finally {
        SetScanBusy(false)
    }
}

SafeDelete(path) {
    global PreserveNames
    name := SplitPathName(path)
    if IsPreserved(name, PreserveNames) {
        Log("[SKIP] Preserved: " path)
        return true
    }
    try {
        FileSetAttrib("-R", path, "F")
        if DirExist(path) {
            return CleanDirPreserving(path, PreserveNames)
        } else {
            FileDelete(path)
            return !FileExist(path)
        }
    } catch {
        return false
    }
}

DelFile(path) {
    return SafeDelete(path)
}

AddAlwaysDelete() {
    global AlwaysDeletePaths
    AddItems("AlwaysDelete", AlwaysDeletePaths)
}

AddWindowsCleanup() {
    global IncludeWindowsCleanup, WindowsTempDirs
    if !IncludeWindowsCleanup
        return
    AddItems("WindowsTemp", WindowsTempDirs)
}

AddGlobalCaches() {
    global IncludeGlobalCaches, GlobalCachePaths
    if !IncludeGlobalCaches
        return
    AddItems("GlobalCache", GlobalCachePaths)
}

AddItems(type, paths) {
    for p in paths {
        p := NormalizePath(p)
        AddItem(type, p, DeletableSize(p))
    }
}

AddSystemPatterns() {
    global SystemFilePatterns, Items
    Loop SystemFilePatterns.Length {
        pattern := SystemFilePatterns[A_Index]
        p := ExpandEnv(pattern)
        try {
            Loop Files, p, "F" { ; Only files, no recursion needed for these patterns
                AddItem("SystemPattern", A_LoopFileFullPath, A_LoopFileSize)
            }
        } catch {
            Log("[ERR] Invalid system pattern: " p)
        }
    }
}

AddProjectCaches() {
    global RootPaths, MarkerFiles, CacheDirPatterns, ExcludeDirSegments, ExcludeExactPaths, MaxDepth, Items, PreserveNames

    for root in RootPaths {
        root := NormalizePath(root)
        if !DirExist(root)
            continue
        For projectDir in EnumerateProjects(root, MaxDepth, MarkerFiles) {
            for pat in CacheDirPatterns {
                targets := FindRelativeMatches(projectDir, pat)
                for tgt in targets {
                    if ShouldExclude(tgt, ExcludeDirSegments, ExcludeExactPaths)
                        continue

						; Skip if the target is itself a preserved file (pattern hit a file)
						if FileExist(tgt) && !DirExist(tgt) {
							name := SplitPathName(tgt)
							if IsPreserved(name, PreserveNames)
								continue
						}


                    AddItem("ProjectCache", tgt, DeletableSize(tgt))
                }
            }
        }
    }
}

EnumerateProjects(root, maxDepth, markerFiles) {
    projects := []
    ScanDir(root, 0)
    return projects

    ScanDir(dir, depth) {
        if (depth > maxDepth)
            return
        if HasAnyMarker(dir, markerFiles) {
            projects.Push(dir)
            ; still descend a little to catch nested workspaces
        }
        loop files dir "\*", "D" {
            sub := A_LoopFileFullPath
            ; skip configured dirs for speed
            skip := false
            for skipDir in SkipDirs {
                if InStr(sub, "\" skipDir "\")
                    skip := true
            }
            if skip
                continue
            ScanDir(sub, depth+1)
        }
    }
}

HasAnyMarker(dir, markerFiles) {
    for mf in markerFiles {
        if FileExist(dir "\" mf)
            return true
    }
    return false
}

FindRelativeMatches(projectDir, pattern) {
    ; pattern can include wildcards and subfolders
    ; Build absolute search
    out := []
    try {
        Loop files projectDir "\" pattern, "FD" {
            out.Push(A_LoopFileFullPath)
        }
    } catch {
        ; ignore bad patterns
    }
    return out
}

ShouldExclude(path, segs, exacts) {
    np := StrLower(path)
    for s in segs {
        if InStr(np, StrLower("\" s "\")) || InStr(np, StrLower("\" s)) || InStr(np, StrLower(s "\"))
            return true
    }
    for e in exacts {
        if StrLower(NormalizePath(e)) = StrLower(NormalizePath(path))
            return true
    }
    return false
}

NormalizePath(p) {
    ; resolve .. and . components via FileGetShortPath / Dir
    ; simplest normalization: remove trailing backslashes
    if SubStr(p, -0) = "\"
        p := RTrim(p, "\")
    return p
}

DeletableSize(path) {
    global PreserveNames, MAX_FILES_SIZE_CALC, TIMEOUT_SIZE_CALC_MS
    if FileExist(path) && !DirExist(path) {
        name := SplitPathName(path)
        return IsPreserved(name, PreserveNames) ? 0 : FileGetSize(path, "B")
    }
    if !DirExist(path)
        return 0

    total := 0
    fileCount := 0
    startTime := A_TickCount

    ; Single recursive files loop is faster than manual dir recursion
    Loop files path "\*", "FR" {
        ; Check for timeout or file count limit
        if (A_TickCount - startTime > TIMEOUT_SIZE_CALC_MS) || (fileCount >= MAX_FILES_SIZE_CALC) {
            Log("[WARN] Size calculation timed out or hit limit for: " path " (processed " fileCount " files)")
            break
        }
        name := A_LoopFileName
        if !IsPreserved(name, PreserveNames) {
            total += A_LoopFileSize  ; uses cached size for the current loop item
            fileCount++
        }
    }
    return total
}

SplitPathName(p) {
    ; returns just the filename
    SplitPath p, &fn
    return fn
}


; ---------------------------
; ------ List & Totals ------
; ---------------------------
PopulateListView() {
	try {
		global LV, Items, MAX_LISTVIEW_ITEMS
		if Items.Length > MAX_LISTVIEW_ITEMS {
			MsgBox "Too many items found (" Items.Length "). Showing first " MAX_LISTVIEW_ITEMS ".", AppTitle, "Icon!"
			Items := Items.Slice(1, MAX_LISTVIEW_ITEMS)
		}
		LV.Opt("-Redraw")
		for idx, item in Items {
			sizeStr := HumanSize(item["size"])
			LV.Add("Check", item["type"], item["path"], sizeStr, item["size"])
		}
		LV.ModifyCol(4, "Float")
		LV.ModifyCol(4, "SortDesc")
		LV.OnEvent("ColClick", OnColClick)
		LV.OnEvent("DoubleClick", OnOpenRow)
		LV.Opt("+Redraw")
	} Catch as e {
		Log("[ERR] PopulateListView: " e.Message)
	}
}

OnColClick(ctrl, col) {
    static dir := 1  ; toggles ASC/DESC
    if (col = 3) {
        ctrl.ModifyCol(4, "Float")               ; ensure numeric sort
        ctrl.ModifyCol(4, dir = 1 ? "Sort" : "SortDesc")  ; sort by bytes
    } else {
        ctrl.ModifyCol(col, dir = 1 ? "Sort" : "SortDesc")
    }
    dir := -dir
}

OnOpenRow(ctrl, row) {
    if (row <= 0)
        return
    path := ctrl.GetText(row, 2)  ; Path column
    if DirExist(path) {
        Run('explorer.exe "' path '"')
    } else if FileExist(path) {
        Run('explorer.exe /select,"' path '"')
    }
}

UpdateTotals() {
	try {
		global TotalLabel, LV
		total := 0
		for row in GetSelectedRows() {
			total += LV.GetText(row, 4)
		}
		TotalLabel.Value := "Recoverable: " HumanSize(total)
		SB("Preview complete. Select/deselect items as needed.")
	} Catch as e {
		Log("[ERR] UpdateTotals: " e.Message)
	}
}

CountSelected() {
    return GetSelectedRows().Length
}

HumanSize(bytes) {
    units := ["B","KB","MB","GB","TB"]
    i := 1
    b := bytes + 0.0
    while (b >= 1024 && i < units.Length) {
        b /= 1024
        i++
    }
    return Format("{:0.2f} {}", b, units[i])
}

SB(msg) {
	try {
		global StatusBar
		StatusBar.SetText(msg)
	} Catch as e {
	}    
}

CheckAllItems(*) {
    global LV
    Loop LV.GetCount() {
        LV.Modify(A_Index, "Check")
    }
    UpdateTotals()
}

UncheckAllItems(*) {
    global LV
    Loop LV.GetCount() {
        LV.Modify(A_Index, "-Check")
    }
    UpdateTotals()
}

; --------------------------- Helper functions ---------------------------

GetSelectedRows() {
    global LV
    rows := []
    row := 0
    Loop {
        row := LV.GetNext(row, "C")
        if !row
            break
        rows.Push(row)
    }
    return rows
}

; ---------------------------
; --------- Delete ----------
; ---------------------------
DoDeleteSelected(*) {
    global Items, ConfirmBeforeDelete, LogFile, LV

    if CountSelected() = 0 {
        MsgBox "Nothing selected.", AppTitle, "Iconx"
        return
    }
    if ConfirmBeforeDelete {
        resp := MsgBox("Delete the selected items?`nThis cannot be undone.", AppTitle, "YesNo Icon!")
        if (resp != "Yes")
            return
    }

    SetUIBusy(true)
    try {
        Log("---- Cleanup started: " A_Now " ----")
        failed := []
        rowsToDelete := []
        row := 0
        Loop {
            row := LV.GetNext(row, "C")
            if !row
                break
            path := LV.GetText(row, 2)
            ok := DeletePath(path)
            if ok {
                Log("[OK ] Deleted: " path)
                rowsToDelete.Push(row)
            } else {
                Log("[ERR] Failed:  " path)
                failed.Push(path)
            }
        }
        Log("---- Cleanup finished: " A_Now " ----`n")

        ; Remove successfully deleted rows from LV (from bottom to top to avoid index shifts)
        reversedRows := []
        for i in rowsToDelete {
            reversedRows.InsertAt(1, i)  ; Reverse the order
        }
        for i in reversedRows {
            LV.Delete(i)
        }

        ; Update totals after removing rows
        UpdateTotals()

        if failed.Length {
            MsgBox "Done with some errors.`nFailed to delete:`n`n" JoinLines(failed), AppTitle, "Iconx"
        } else {
            MsgBox "Cleanup complete.", AppTitle, "Iconi"
        }

        ; Re-scan to refresh the list with current state
        ScanAndPopulate()
    } finally {
        SetUIBusy(false)
    }
}

DeletePath(path) {
    try {
        return SafeDelete(path)
    } catch {
        ; Retry once after clearing read-only
        try FileSetAttrib("-R", path, "F")
        return SafeDelete(path)
    } catch {
        return false
    }
}

CleanDirPreserving(dir, preserveList) {
    ; delete all files except preserved names, and recurse into subdirs applying same rule
    ; returns true if no exception occurred (we're lenient)
    try {
        ; Combined loop for files and dirs
        Loop files dir "\*", "FD" {
            if InStr(A_LoopFileAttrib, "D") {
                ; Directory
                CleanDirPreserving(A_LoopFileFullPath, preserveList)
                if DirIsEmpty(A_LoopFileFullPath)
                    DirDelete(A_LoopFileFullPath)
            } else {
                ; File
                name := A_LoopFileName
                if !IsPreserved(name, preserveList) {
                    FileSetAttrib("-R", A_LoopFileFullPath, "F")
                    DelFile(A_LoopFileFullPath)
                } else {
                    Log("[PRESERVE] Keeping file: " A_LoopFileFullPath)
                }
            }
        }
        return true
    } catch {
        return false
    }
}

IsPreserved(name, preserveList) {
    n := StrLower(Trim(name))
    for p in preserveList {
        if (n = StrLower(Trim(p))) {
            return true
        }
    }
    return false
}

DirIsEmpty(dir) {
    for _ in DirExist(dir) ? DirGetFilesAndDirs(dir) : []
        return false
    return true
}

DirGetFilesAndDirs(dir) {
    arr := []
    Loop files dir "\*", "FD" {
        arr.Push(A_LoopFileName)
    }
    return arr
}

JoinLines(arr) {
    s := ""
    for v in arr
        s .= v "`n"
    return RTrim(s, "`n")
}

Log(msg) {
    global LogFile

    ; Create a more explicit log file path if LogFile is not properly set
    if (!LogFile || LogFile = "") {
        LogFile := A_ScriptDir "\cleanup.log"
    }

    ; Expand environment variables properly
    expandedPath := ExpandEnv(LogFile)
    if (expandedPath = LogFile && InStr(LogFile, "%")) {
        ; If ExpandEnv didn't work, fall back to script directory
        expandedPath := A_ScriptDir "\cleanup.log"
    }

    ; Always show where we're logging to (at least once)
    static logLocationShown := false
    if (!logLocationShown) {
        try FileAppend("=== LOG FILE LOCATION: " expandedPath " ===`n", expandedPath)
        logLocationShown := true
    }

    try {
        FileAppend(FormatTime(A_Now, "yyyyMMddHHmmss") "  " msg "`n", expandedPath)
    } catch {
        ; If that fails, try the script directory
        try FileAppend(FormatTime(A_Now, "yyyyMMddHHmmss") "  " msg "`n", A_ScriptDir "\emergency_log.log")
    }
}

CleanupOnExit(*) {
    Log("Script exited cleanly.")
}

