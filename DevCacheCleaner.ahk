 
; CleanupDevCache.ahk  —  AutoHotkey v2
; A safe, GUI-based dev cache cleaner for Windows 11
; - Shows a preview (paths + sizes) first
; - Deletes only after user confirmation
; - Respects config.ini for roots, patterns, exclusions, and optional Windows/global caches
; Tested with AutoHotkey v2.x

#Requires AutoHotkey v2.0+
#SingleInstance Force
Persistent
ProcessSetPriority "High"

; ---------------------------
; ---- Config & Defaults ----
; ---------------------------
global AppTitle := "Cleanup Dev Cache (AHK)"
global IniFile  := A_ScriptDir "\cleanup.ini"
global MaxDepth := 8
global IncludeWindowsCleanup := true
global IncludeGlobalCaches   := true
global ConfirmBeforeDelete   := true
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

; UI globals
global LV, TotalLabel, StatusBar, DeleteBtn, RefreshBtn, OpenBtn
global Items := [] ; array of maps: {type, path, size, selected}

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
, path)
}

ReadConfig(path) {
    global MaxDepth, PreserveNames, IncludeWindowsCleanup, IncludeGlobalCaches, ConfirmBeforeDelete, LogFile
    global RootPaths, AlwaysDeletePaths, MarkerFiles, CacheDirPatterns, ExcludeDirSegments, ExcludeExactPaths, WindowsTempDirs, GlobalCachePaths

    ; General
    ConfirmBeforeDelete := IniRead(path, "General", "ConfirmBeforeDelete", 1) = 1
    MaxDepth := Integer(IniRead(path, "General", "MaxDepth", 8))
    IncludeWindowsCleanup := IniRead(path, "General", "IncludeWindowsCleanup", 1) = 1
    IncludeGlobalCaches   := IniRead(path, "General", "IncludeGlobalCaches", 1) = 1
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
    ; Expand %ENV% variables
    if !InStr(path, "%")
        return path
    ; Use AHK's EnvGet for each token
    out := ""
    i := 1
    while i <= StrLen(path) {
        if SubStr(path, i, 1) = "%" {
            j := InStr(path, "%", false, i+1)
            if j {
                var := SubStr(path, i+1, j-i-1)
                val := EnvGet(var)
                if val = ""
                    val := "%" var "%" ; leave as-is if undefined
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
    global LV, TotalLabel, StatusBar, DeleteBtn, RefreshBtn, OpenBtn, ExitBtn

    GuiTitle := AppTitle "  —  Preview"
    myGui := Gui("+Resize", GuiTitle)
    myGui.MarginX := 10, myGui.MarginY := 10

	RefreshBtn := myGui.Add("Button", "x10 y10", "Refresh")
	RefreshBtn.GetPos(&rx, &ry, &rw, &rh)
    RefreshBtn.OnEvent("Click", ScanAndPopulate)

	DeleteBtn  := myGui.Add("Button", "x+10 yp Default", "Delete Selected…")
	DeleteBtn.GetPos(&dx, &dy, &dw, &dh)
    DeleteBtn.OnEvent("Click", DoDeleteSelected)

	OpenBtn := myGui.Add("Button", "x+10 yp", "Open Config")
	OpenBtn.OnEvent("Click", (*) => Run(A_ComSpec ' /c start "" "' IniFile '"'))
	
	ExitBtn := myGui.Add("Button", "x+10 yp w80 h30", "Exit")
	ExitBtn.OnEvent("Click", (*) => ExitApp())

    TotalLabel := myGui.Add("Text", "x10 y+10 w800", "Total to recover: calculating…")
    
    myGui.SetFont("s10")  ; bigger list font

    LV := myGui.Add("ListView", "x10 y+5 w1050 r30 Grid Checked")
    myGui.SetFont()       ; reset to default for later controls
    
	LV.InsertCol(1, "", "Type")
	LV.InsertCol(2, "", "Path")
	LV.InsertCol(3, "", "Size")
	LV.InsertCol(4, "", "Bytes")   ; hidden numeric sort key
	LV.ModifyCol(4, "Integer")     ; <- numeric sort
	LV.ModifyCol(4, 0)             ; keep hidden
	
    LV.ModifyCol(1, 180), LV.ModifyCol(2, 760), LV.ModifyCol(3, 100)
    LV.OnEvent("Click", (ctrl, row) => (row ? (Items[row]["selected"] := ctrl.GetNext(row-1, "C"), UpdateTotals()) : 0))

    StatusBar := myGui.Add("StatusBar")
    myGui.OnEvent("Size", OnResize)

    myGui.Show("w1100 h700 Center")
}

SetScanBusy(flag) {
    global RefreshBtn, DeleteBtn, OpenBtn, ExitBtn, LV
    ; Disable everything except Exit while scanning
    for ctrl in [RefreshBtn, DeleteBtn, OpenBtn, LV] {
        try ctrl.Enabled := !flag
    }
    ; Exit stays enabled
}

SetUIBusy(flag) {
    global RefreshBtn, DeleteBtn, OpenBtn, ExitBtn, LV, StatusBar
    for ctrl in [RefreshBtn, DeleteBtn, OpenBtn, ExitBtn, LV] {
        try ctrl.Enabled := !flag
    }
    SB(flag ? "Deleting… please wait." : "Ready.")
}

OnResize(gui, minMax, width, height) {
    global LV, TotalLabel, RefreshBtn, DeleteBtn, OpenBtn, ExitBtn, StatusBar
    
    if (minMax = -1) ; minimized
        return

	RefreshBtn.Move(10, 10)
	RefreshBtn.GetPos(&rx, &ry, &rw, &rh)

	DeleteBtn.Move(rx + rw + 10, ry)
	DeleteBtn.GetPos(&dx, &dy, &dw, &dh)

	OpenBtn.Move(dx + dw + 10, ry)
	
	ExitBtn.GetPos(, , &ew, &eh)           ; get its current width/height
    ExitBtn.Move(width - 10 - ew, 10)      ; 10px right margin

	TotalLabel.Move(10, ry + rh + 10, width - 20)
	TotalLabel.GetPos(&tx, &ty, &tw, &th)

	LV.Move(10, ty + th + 5, width - 20, height - (ty + th + 5) - 40)
	StatusBar.Move(, height - 30, width, 22)

}

AddItem(type, path, size) {
    global Items, SeenPaths
    p := NormalizePath(path)
    key := StrLower(p)
    if SeenPaths.Has(key)
        return
    if !FileExist(p)
        return
    SeenPaths[key] := true
    Items.Push(Map("type", type, "path", p, "size", size, "selected", true))
}

; ---------------------------
; ---- Scanning & Sizes -----
; ---------------------------
ScanAndPopulate(*) {
    global Items, LV, SeenPaths
    SetScanBusy(true)
    try {
        Items := []
        SeenPaths := Map()  ; key = normalized lowercase absolute path
        LV.Delete()
        SB("Scanning… this may take a bit on big folders.")

        AddAlwaysDelete()
        AddWindowsCleanup()
        AddGlobalCaches()
        AddProjectCaches()

        PopulateListView()
        UpdateTotals()
        SB("Ready.")
    } finally {
        SetScanBusy(false)
    }
}

DelFile(path) {
    global PreserveNames
    name := SplitPathName(path)
    if IsPreserved(name, PreserveNames) {
        Log("[SKIP] Preserved file: " path)
        return true  ; Return true to indicate "success" (file was preserved as intended)
    }
    try {
        FileSetAttrib("-R", path, "F")  ; clear read-only on the file
        FileDelete(path)
        return !FileExist(path)
    } catch {
        return false
    }
}

AddAlwaysDelete() {
    global AlwaysDeletePaths, Items
    for p in AlwaysDeletePaths {
        p := NormalizePath(p)
        AddItem("AlwaysDelete", p, DeletableSize(p))
    }
}

AddWindowsCleanup() {
    global IncludeWindowsCleanup, WindowsTempDirs, Items
    if !IncludeWindowsCleanup
        return
    for p in WindowsTempDirs {
        p := NormalizePath(p)
        AddItem("WindowsTemp", p, DeletableSize(p))
    }
}

AddGlobalCaches() {
    global IncludeGlobalCaches, GlobalCachePaths, Items
    if !IncludeGlobalCaches
        return
    for p in GlobalCachePaths {
        p := NormalizePath(p)
        AddItem("GlobalCache", p, DeletableSize(p))
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
            ; skip node_modules etc for speed
               if InStr(sub, "\node_modules\") 
             || InStr(sub, "\.git\")
             || InStr(sub, "\vendor\")
             || InStr(sub, "\.venv\")
             || InStr(sub, "\.next\")
             || InStr(sub, "\.nuxt\")
             || InStr(sub, "\dist\")
             || InStr(sub, "\build\")
             || InStr(sub, "\obj\")
             || InStr(sub, "\bin\")
             || InStr(sub, "\target\")
             || InStr(sub, "\.gradle\")
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
    global PreserveNames
    if FileExist(path) && !DirExist(path) {
        name := SplitPathName(path)
        return IsPreserved(name, PreserveNames) ? 0 : FileGetSize(path, "B")
    }
    if !DirExist(path)
        return 0

    total := 0
    ; Single recursive files loop is faster than manual dir recursion
    Loop files path "\*", "FR" {
        name := A_LoopFileName
        if !IsPreserved(name, PreserveNames)
            total += A_LoopFileSize  ; uses cached size for the current loop item
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
    global LV, Items
    LV.Opt("-Redraw")  ; <-- add
    for idx, item in Items {
        sizeStr := HumanSize(item["size"])
        LV.Add("Check", item["type"], item["path"], sizeStr, item["size"])
        LV.Modify(idx, item["selected"] ? "Check" : "UnCheck")
    }
    LV.ModifyCol(4, "Integer")
    LV.ModifyCol(4, "SortDesc")
    LV.OnEvent("ColClick", OnColClick)
    LV.OnEvent("DoubleClick", OnOpenRow)
    LV.Opt("+Redraw")  ; <-- add
}

OnColClick(ctrl, col) {
    static dir := 1  ; toggles ASC/DESC
    if (col = 3) {
        ctrl.ModifyCol(4, "Integer")               ; ensure numeric sort
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
    global Items, TotalLabel, LV
    total := 0
    for it in Items
        If it["selected"]
            total += it["size"]
    TotalLabel.Value := "Total to recover (selected): " HumanSize(total) "  —  Items: " CountSelected() "/" Items.Length
    SB("Preview complete. Select/deselect items as needed.")
}

CountSelected() {
    global Items
    c := 0
    for it in Items
        if it["selected"]
            c++
    return c
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
    global StatusBar
    StatusBar.SetText(msg)
}

; ---------------------------
; --------- Delete ----------
; ---------------------------
DoDeleteSelected(*) {
    global Items, ConfirmBeforeDelete, LogFile

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
        for it in Items {
            if !it["selected"]
                continue
            path := it["path"]
            ok := DeletePath(path)
            if ok
                Log("[OK ] Deleted: " path)
            else {
                Log("[ERR] Failed:  " path)
                failed.Push(path)
            }
        }
        Log("---- Cleanup finished: " A_Now " ----`n")

        if failed.Length {
            MsgBox "Done with some errors.`nFailed to delete:`n`n" JoinLines(failed), AppTitle, "Iconx"
        } else {
            MsgBox "Cleanup complete.", AppTitle, "Iconi"
        }
        ScanAndPopulate()
    } finally {
        SetUIBusy(false)
    }
}

DeletePath(path) {
    global PreserveNames
    try {
        if DirExist(path) {
            return CleanDirPreserving(path, PreserveNames)
        } else if FileExist(path) {
            name := SplitPathName(path)
            
            if IsPreserved(name, PreserveNames) {
                Log("[PRESERVE] Keeping file: " path)
                return true  ; Don't try to delete preserved files
            }
            
            return DelFile(path)
        }
    } catch {
        ; try removing read-only then retry once
        try FileSetAttrib("-R", path, "F")  ; target file
        try {
            if DirExist(path)
                return CleanDirPreserving(path, PreserveNames)
            else if FileExist(path) {
                name := SplitPathName(path)
                if IsPreserved(name, PreserveNames) {
                    Log("[PRESERVE] Keeping file: " path)
                    return true
                }
                return DelFile(path)
            }
        } catch {
            return false
        }
    }
    return false
}

CleanDirPreserving(dir, preserveList) {
    ; delete all files except preserved names, and recurse into subdirs applying same rule
    ; returns true if no exception occurred (we're lenient)
    try {
        ; files
        Loop files dir "\*", "F" {
            name := A_LoopFileName
            if !IsPreserved(name, preserveList) {
                try FileSetAttrib("-R", A_LoopFileFullPath, "F")
                ; Only attempt to delete if file is not preserved
                DelFile(A_LoopFileFullPath)
            } else {
                ; Log that we're preserving this file
                Log("[PRESERVE] Keeping file: " A_LoopFileFullPath)
            }
        }
        ; dirs
        Loop files dir "\*", "D" {
            CleanDirPreserving(A_LoopFileFullPath, preserveList)
            if DirIsEmpty(A_LoopFileFullPath)
                DirDelete(A_LoopFileFullPath)
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

