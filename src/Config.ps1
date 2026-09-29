function Assert-TemenosRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        [System.IO.Path]::IsPathRooted($Value) -or
        $Value -match '(^|[\\/])\.{1,2}([\\/]|$)') {
        throw "Invalid relative path in Temenos.json: $Field"
    }

    return $Value
}

function Import-TemenosConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Could not read Temenos.json: $($_.Exception.Message)"
    }

    if ($data.version -ne 1) {
        throw "Unsupported Temenos.json version. Expected version 1."
    }

    $pathNames = @{}
    foreach ($requiredPath in @('common', 'wallpapers', 'wallpaperCache')) {
        if (-not $data.paths -or -not $data.paths.PSObject.Properties[$requiredPath]) {
            throw "Missing paths.$requiredPath in Temenos.json."
        }
        $rawPath = $data.paths.$requiredPath
        if ($rawPath -isnot [string]) { throw "paths.$requiredPath must be a string." }
        $value = Assert-TemenosRelativePath -Value $rawPath -Field "paths.$requiredPath"
        if ($pathNames.ContainsKey($value)) { throw "Runtime paths must be unique: $value" }
        $pathNames[$value] = $true
    }

    if (-not $data.workspaces) {
        throw "Temenos.json must define at least one workspace."
    }

    $workspaces = @{}
    $folderNames = @{}
    foreach ($property in $data.workspaces.PSObject.Properties) {
        if ($property.Name -notmatch '^[1-9][0-9]*$') {
            throw "Invalid workspace id '$($property.Name)' in Temenos.json. Use positive numbers."
        }

        $entry = $property.Value
        if ($null -eq $entry -or -not $entry.PSObject.Properties['folder'] -or
            -not $entry.PSObject.Properties['name'] -or -not $entry.PSObject.Properties['wallpaper']) {
            throw "Workspace $($property.Name) must define name, folder, and wallpaper."
        }

        if ($entry.folder -isnot [string]) { throw "Workspace $($property.Name) folder must be a string." }
        $folder = Assert-TemenosRelativePath -Value $entry.folder -Field "workspaces.$($property.Name).folder"
        if ($pathNames.ContainsKey($folder)) { throw "Workspace folder conflicts with a shared runtime path: $folder" }
        if ($folderNames.ContainsKey($folder)) {
            throw "Workspace folders must be unique: $folder"
        }
        $folderNames[$folder] = $true

        $name = ''
        if ($null -ne $entry.name) {
            if ($entry.name -isnot [string]) { throw "Workspace $($property.Name) name must be a string or null." }
            $name = [string]$entry.name
        }

        $wallpaper = $null
        if ($null -ne $entry.wallpaper) {
            if ($entry.wallpaper -isnot [string]) { throw "Workspace $($property.Name) wallpaper must be a string or null." }
            if (-not [string]::IsNullOrWhiteSpace($entry.wallpaper)) {
                $wallpaper = Assert-TemenosRelativePath -Value $entry.wallpaper -Field "workspaces.$($property.Name).wallpaper"
            }
        }

        $workspaces[[int]$property.Name] = [pscustomobject]@{
            Name = $name
            Folder = $folder
            Wallpaper = $wallpaper
        }
    }

    if ($workspaces.Count -eq 0) {
        throw "Temenos.json must define at least one workspace."
    }

    return [pscustomobject]@{
        Version = 1
        Paths = [pscustomobject]@{
            Common = [string]$data.paths.common
            Wallpapers = [string]$data.paths.wallpapers
            WallpaperCache = [string]$data.paths.wallpaperCache
        }
        Workspaces = $workspaces
    }
}

function Get-TemenosWorkspace {
    param([Parameter(Mandatory = $true)][int]$WorkspaceIndex)

    if ($Config.Workspaces.ContainsKey($WorkspaceIndex)) {
        return $Config.Workspaces[$WorkspaceIndex]
    }

    return $null
}
