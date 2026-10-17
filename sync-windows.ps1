# ============================================================
# YouTubeSync PC v19-win — ScafNet
# Versione Windows (PowerShell 5.1) dello script del Mac v19.
#  - v19: brani non disponibili divisi in CANCELLATI/PRIVATI e BLOCCATI
#    (link di ricerca per trovare un'altra versione); a fine giro Max puo'
#    aprire una pagina con tutti i link cliccabili (L + INVIO).
#  - Si aggiorna da solo da GitHub (sync-windows.ps1) e aggiorna anche
#    "Gestisci playlist" (gestisci-playlist-windows.ps1).
#  - Scarica da solo yt-dlp, ffmpeg e deno nella sua cartella bin.
#  - Lista playlist dal foglio di Stefano (stesso foglio del Mac).
#  - Cartelle complete: un brano in piu' playlist si scarica una volta
#    sola; nelle altre cartelle e' un "collegamento fisico" NTFS
#    (zero spazio in piu').
#  - Rimozioni: doppione tolto se esiste altrove, altrimenti _RIMOSSI;
#    ripristino da _RIMOSSI se il brano torna in playlist.
#  - Secondo tentativo per i bloccati, classificazione errori.
#  - Controllo connessione, nomi delle playlist non raggiungibili.
#  - Log completo nel foglio, marcato "PC Windows".
# ============================================================

$AppVersion = 'v19-win'
$GhRaw  = 'https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/sync-windows.ps1'
$MgrRaw = 'https://raw.githubusercontent.com/stefanoscafnet/youtubesync/main/gestisci-playlist-windows.ps1'

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'YouTubeSync' } catch {}

$AppDir   = $PSScriptRoot
$SelfPath = $PSCommandPath
$Utf8     = New-Object System.Text.UTF8Encoding($false)
$IsWin    = ($env:OS -eq 'Windows_NT')

# ---------------------------------------------------------------- rete
function Get-Text([string]$url) {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    return $wc.DownloadString($url)
}
function Get-File([string]$url, [string]$path) {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $path)
}
function Escape-Long([string]$s) {
    # [Uri]::EscapeDataString a pezzi (vecchi .NET hanno un limite di lunghezza)
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $n = [Math]::Min(20000, $s.Length - $i)
        if (($i + $n) -lt $s.Length -and [char]::IsHighSurrogate($s[$i + $n - 1])) { $n-- }
        [void]$sb.Append([Uri]::EscapeDataString($s.Substring($i, $n)))
        $i += $n
    }
    return $sb.ToString()
}
function Post-Form([string]$url, [System.Collections.Specialized.OrderedDictionary]$fields) {
    $parts = @()
    foreach ($k in $fields.Keys) { $parts += ((Escape-Long $k) + '=' + (Escape-Long ([string]$fields[$k]))) }
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return $wc.UploadString($url, 'POST', ($parts -join '&'))
}
function Test-ScriptFile([string]$path) {
    $tokens = $null; $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    return ($errs.Count -eq 0)
}

# ------------------------------------------------ auto-aggiornamento script
if (-not $env:YTS_SELFUPDATE_DONE) {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Get-File $GhRaw $tmp
        if ((Get-Item -LiteralPath $tmp).Length -gt 1000 -and
            (Select-String -LiteralPath $tmp -Pattern 'YouTubeSync PC v' -SimpleMatch -Quiet) -and
            (Test-ScriptFile $tmp)) {
            if ((Get-FileHash -LiteralPath $tmp).Hash -ne (Get-FileHash -LiteralPath $SelfPath).Hash) {
                Copy-Item -LiteralPath $tmp -Destination $SelfPath -Force
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
                $env:YTS_SELFUPDATE_DONE = '1'
                $psExe = (Get-Process -Id $PID).Path
                & $psExe -NoProfile -ExecutionPolicy Bypass -File $SelfPath
                exit $LASTEXITCODE
            }
        }
    } catch {
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# --------------------------------- installa / aggiorna "Gestisci playlist"
$MgrPath = Join-Path $AppDir 'gestisci-playlist-windows.ps1'
$MgrStatus = ''
$tmp = [IO.Path]::GetTempFileName()
try {
    Get-File $MgrRaw $tmp
    if ((Get-Item -LiteralPath $tmp).Length -gt 1000 -and
        (Select-String -LiteralPath $tmp -Pattern 'YouTubeSync PC Gestisci playlist' -SimpleMatch -Quiet) -and
        (Test-ScriptFile $tmp)) {
        $same = (Test-Path -LiteralPath $MgrPath) -and ((Get-FileHash -LiteralPath $tmp).Hash -eq (Get-FileHash -LiteralPath $MgrPath).Hash)
        if (-not $same) {
            if (Test-Path -LiteralPath $MgrPath) { $MgrStatus = 'aggiornato' } else { $MgrStatus = 'installato' }
            Copy-Item -LiteralPath $tmp -Destination $MgrPath -Force
        }
    }
} catch {
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- config
$EndpointUrl = ''
$cfg = Join-Path $AppDir 'config.ps1'
if (Test-Path -LiteralPath $cfg) { . $cfg }

$MusicRoot = [Environment]::GetFolderPath('MyMusic')
if (-not $MusicRoot -or $MusicRoot -match 'OneDrive') { $MusicRoot = Join-Path $env:USERPROFILE 'Music' }
$Dest        = Join-Path $MusicRoot 'Youtube'
$Removed     = Join-Path $Dest '_RIMOSSI'
$LogFile     = Join-Path $Dest 'youtube_sync_pc.log'
$CacheFile   = Join-Path $Dest 'playlist_cache_pc.txt'
$NamesCache  = Join-Path $Dest '.playlist_names_pc.tsv'
$OfflineFile = Join-Path $Dest '.giri_senza_internet_pc.txt'
$Bin         = Join-Path $AppDir 'bin'
$YtDlp       = Join-Path $Bin 'yt-dlp.exe'
$Stamp       = Join-Path $AppDir '.ytdlp_update_stamp'
$DetailMax   = 45000
$LogKeep     = 5000
$RetryClients = @('tv', 'web_safari')
$NetOpts  = @('--retries', '5', '--fragment-retries', '5', '--extractor-retries', '3')
$MetaOpts = @('--retries', '5', '--extractor-retries', '3')

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$Work = Join-Path ([IO.Path]::GetTempPath()) ('yts_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$env:PATH = $Bin + [IO.Path]::PathSeparator + $env:PATH

# ---------------------------------------------------------------- stato
$S = @{ Valid = 0; Skipped = 0; Unreach = 0; New = 0; Cloned = 0; Restored = 0; Removed = 0; DupDel = 0
        RetryOk = 0; DlErr = 0; Dead = 0; Bot = 0; E403 = 0; E429 = 0; MissDead = 0; MissOther = 0; MissGone = 0; MissBlocked = 0 }
$Report = New-Object System.Collections.Generic.List[object]
$DeadList = New-Object System.Collections.Generic.List[object]
$NamesOut = New-Object System.Collections.Generic.List[string]
$RunLog = New-Object System.Collections.Generic.List[string]
$Start = Get-Date

function Log([string]$msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $msg
    $RunLog.Add($line)
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8) } catch {}
}
function LogRaw([string]$line) {
    $RunLog.Add($line)
    try { [IO.File]::AppendAllText($LogFile, $line + "`r`n", $Utf8) } catch {}
}

# ------------------------------------------------------------ interfaccia
function Draw-Header {
    Clear-Host
    Write-Host ''
    Write-Host '   ================================================' -ForegroundColor DarkRed
    Write-Host ('      YouTubeSync      ' + $AppVersion) -ForegroundColor White
    Write-Host '   ================================================' -ForegroundColor DarkRed
    Write-Host ''
}
function Draw-Simple([string]$text) { Draw-Header; Write-Host ('      ' + $text) }
function Draw-Progress([int]$idx, [int]$total, [string]$name, [string]$stage) {
    $bl = 30; $f = 0
    if ($total -gt 0) { $f = [Math]::Min($bl, [int][Math]::Floor($idx * $bl / $total)) }
    $bar = ('#' * $f) + ('.' * ($bl - $f))
    Draw-Header
    Write-Host '      Sincronizzazione in corso...'
    Write-Host ''
    Write-Host ('      [' + $bar + ']  ' + $idx + ' / ' + $total) -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('      >  ' + $name) -ForegroundColor White
    Write-Host ('         ' + $stage) -ForegroundColor Gray
    Write-Host ''
    Write-Host ('      Brani nuovi scaricati:  ' + $S.New)
    if ($S.Cloned -gt 0) { Write-Host ('      Brani aggiunti da altre playlist:  ' + $S.Cloned) }
    Write-Host ''
    Write-Host ''
    Write-Host '      (lascia pure la finestra aperta, ci penso io)' -ForegroundColor DarkGray
}
function Wait-Close {
    Write-Host ''
    Write-Host ''
    [void](Read-Host '      Premi INVIO per chiudere')
}
function Finish([int]$code) {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    Wait-Close
    exit $code
}

# ------------------------------------------------------------- yt-dlp
function Quote-Arg([string]$a) {
    if ($a -eq '' -or $a -match '[\s"]') {
        $q = $a -replace '(\\*)"', '$1$1\"'
        $q = $q -replace '(\\+)$', '$1$1'
        return '"' + $q + '"'
    }
    return $a
}
function Run-Yt([string[]]$argList, [string]$outFile, [string]$errFile) {
    $all = @('--encoding', 'utf-8') + $argList
    $argStr = ($all | ForEach-Object { Quote-Arg $_ }) -join ' '
    $p = Start-Process -FilePath $YtDlp -ArgumentList $argStr -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    return $p.ExitCode
}
function Read-Lines([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8) | Where-Object { $_ -ne '' })
}

# --------------------------------------------- collegamenti fisici NTFS
$HardLinkOk = $false
if ($IsWin) {
    try {
        Add-Type -Namespace YTS -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, System.IntPtr lpSecurityAttributes);
'@ -ErrorAction Stop
        $HardLinkOk = $true
    } catch { $HardLinkOk = $false }
}
function Link-OrCopy([string]$src, [string]$dst) {
    if ($HardLinkOk) {
        try { if ([YTS.Native]::CreateHardLink($dst, $src, [IntPtr]::Zero)) { return $true } } catch {}
    }
    try { Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop; return $true } catch { return $false }
}

# ---------------------------------------------- indice dei file (id -> percorsi)
$IdRe = '\[([A-Za-z0-9_-]{11})\]\.mp3$'
function Build-Index {
    $script:Index = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]'
    Get-ChildItem -LiteralPath $Dest -Recurse -File -Filter '*.mp3' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -cmatch $IdRe) {
            $id = $Matches[1]
            if (-not $script:Index.ContainsKey($id)) { $script:Index[$id] = New-Object System.Collections.Generic.List[string] }
            $script:Index[$id].Add($_.FullName)
        }
    }
}
function Ids-InFolder([string]$folder) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    Get-ChildItem -LiteralPath $folder -File -Filter '*.mp3' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -cmatch $IdRe) { [void]$set.Add($Matches[1]) }
    }
    return ,$set
}
function Under([string]$path, [string]$dir) {
    return $path.StartsWith($dir.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Find-Source([string]$id, [string]$folder) {
    if (-not $script:Index.ContainsKey($id)) { return $null }
    $fromRemoved = $null
    foreach ($p in $script:Index[$id]) {
        if (Under $p $folder) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (Under $p $Removed) { if (-not $fromRemoved) { $fromRemoved = $p } }
        else { return $p }
    }
    return $fromRemoved
}
function Other-Copy([string]$id, [string]$folder) {
    if (-not $script:Index.ContainsKey($id)) { return $null }
    foreach ($p in $script:Index[$id]) {
        if ((Under $p $folder) -or (Under $p $Removed)) { continue }
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Safe-Name([string]$n) {
    $s = $n -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $s = $s.Trim().TrimEnd('.').Trim()
    if ($s -eq '') { $s = 'playlist' }
    return $s
}

function Is-GoneTitle([string]$t) {
    return (@('', 'NA', '[Deleted video]', '[Private video]', '[Video eliminato]', '[Video privato]') -contains $t.Trim())
}
function Search-Url([string]$t, [int]$max) {
    $q = (($t -replace '[\[\]\(\)]', ' ') -replace '\s+', ' ').Trim()
    $e = ([Uri]::EscapeDataString($q)) -replace '%20', '+'
    if ($max -gt 0 -and $e.Length -gt $max) {
        $e = $e.Substring(0, $max)
        if ($e.Contains('+')) { $e = $e.Substring(0, $e.LastIndexOf('+')) }
        $e = $e -replace '%[0-9A-Fa-f]?$', ''
    }
    return 'https://youtube.com/results?search_query=' + $e
}

# ================================================================== AVVIO
Draw-Simple 'Avvio in corso...'
Log ('inizio sincronizzazione (' + $AppVersion + ', PC Windows)')
if ($MgrStatus) { Log ('"Gestisci playlist" ' + $MgrStatus) }

# --- connessione ---
$online = $false
try {
    $req = [System.Net.WebRequest]::Create('https://www.youtube.com')
    $req.Method = 'HEAD'; $req.Timeout = 15000
    $resp = $req.GetResponse(); $resp.Close(); $online = $true
} catch [System.Net.WebException] {
    if ($_.Exception.Response) { $online = $true }
} catch {}
if (-not $online) {
    Draw-Header
    Write-Host '      Nessuna connessione a internet.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      Controlla il Wi-Fi e riprova.'
    Write-Host '      Non ho toccato nessun file.'
    Log 'NESSUNA CONNESSIONE: sync non eseguito'
    [IO.File]::AppendAllText($OfflineFile, (Get-Date -Format 'yyyy-MM-dd HH:mm') + " tentativo di sync senza internet`r`n", $Utf8)
    Finish 0
}
$OfflineNote = ''
if ([IO.File]::Exists($OfflineFile) -and (New-Object IO.FileInfo($OfflineFile)).Length -gt 0) {
    $off = @(Read-Lines $OfflineFile)
    Log ('nota: dal giro precedente ' + $off.Count + ' tentativi senza internet:')
    foreach ($l in $off) { LogRaw ('     ' + $l) }
    $OfflineNote = ', giri_senza_internet_prima:' + $off.Count
    Remove-Item -LiteralPath $OfflineFile -Force -ErrorAction SilentlyContinue
}

# --- strumenti (yt-dlp, ffmpeg, deno) ---
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
function Expand-Pick([string]$zipUrl, [string[]]$names, [string]$what) {
    $zip = Join-Path $Work ($what + '.zip'); $ex = Join-Path $Work ($what + '_x')
    Get-File $zipUrl $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
    foreach ($n in $names) {
        $f = Get-ChildItem -LiteralPath $ex -Recurse -File -Filter $n | Select-Object -First 1
        if ($f) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Bin $n) -Force }
    }
}
try {
    if (-not (Test-Path -LiteralPath $YtDlp)) {
        Draw-Simple 'Prima installazione: scarico yt-dlp...'
        Get-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $YtDlp
        Log 'installato yt-dlp'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'ffmpeg.exe'))) {
        Draw-Simple 'Prima installazione: scarico ffmpeg (circa 150 MB, qualche minuto)...'
        Expand-Pick 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip' @('ffmpeg.exe', 'ffprobe.exe') 'ffmpeg'
        Log 'installato ffmpeg'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Bin 'deno.exe'))) {
        Draw-Simple 'Prima installazione: scarico deno...'
        Expand-Pick 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' @('deno.exe') 'deno'
        Log 'installato deno'
    }
} catch {
    Log ('ERRORE installazione strumenti: ' + $_.Exception.Message)
}
$missing = @()
foreach ($t in @('yt-dlp.exe', 'ffmpeg.exe')) { if (-not (Test-Path -LiteralPath (Join-Path $Bin $t))) { $missing += $t } }
if ($missing.Count -gt 0) {
    Draw-Header
    Write-Host ('      Manca un componente (' + ($missing -join ', ') + ').') -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      Riprova tra poco; se succede ancora, chiama Stefano.'
    Log ('ERRORE componente mancante: ' + ($missing -join ', '))
    Finish 1
}

# --- aggiornamento yt-dlp (max 1 volta al giorno) ---
$needUpd = (-not [IO.File]::Exists($Stamp)) -or ((New-Object IO.FileInfo($Stamp)).LastWriteTime -lt (Get-Date).AddDays(-1))
if ($needUpd) {
    Draw-Simple 'Controllo aggiornamenti...'
    $o = Join-Path $Work 'upd.out'; $e = Join-Path $Work 'upd.err'
    [void](Run-Yt @('-U', '--update-to', 'stable') $o $e)
    $txt = (@(Read-Lines $o) + @(Read-Lines $e)) -join "`n"
    if ($txt -match 'Updated yt-dlp to\s+(\S+)') { Log ('   yt-dlp aggiornato a ' + $Matches[1]) }
    elseif ($txt -match 'up to date') { Log '   yt-dlp gia'' all''ultima versione' }
    else { Log '   aggiornamento yt-dlp: nessuna risposta chiara' }
    Set-Content -LiteralPath $Stamp -Value (Get-Date -Format s)
}
$o = Join-Path $Work 'ver.out'; $e = Join-Path $Work 'ver.err'
[void](Run-Yt @('--version') $o $e)
$YtVer = (Read-Lines $o | Select-Object -First 1)
Log ('yt-dlp versione: ' + $YtVer)

# --- lista playlist (foglio -> cache) ---
$Lines = @()
if ($EndpointUrl -match '^https') {
    try {
        $txt = Get-Text ($EndpointUrl + '?action=list')
        if ($txt -and $txt.Trim() -ne '') {
            [IO.File]::WriteAllText($CacheFile, $txt, $Utf8)
            Log 'lista playlist aggiornata da internet'
        }
    } catch { Log 'AVVISO foglio non raggiungibile: uso la lista in cache' }
}
if (Test-Path -LiteralPath $CacheFile) { $Lines = @(Read-Lines $CacheFile) }
if ($Lines.Count -eq 0) {
    Draw-Header
    Write-Host '      Non trovo la lista delle playlist.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      Chiama Stefano.'
    Log 'ERRORE nessuna lista playlist disponibile.'
    Finish 1
}
$Total = @($Lines | Where-Object { $_ -match 'list=' }).Count
if ($Total -eq 0) { $Total = 1 }

# --- nomi gia' visti (cache locale) ---
$NameCache = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($l in (Read-Lines $NamesCache)) { $p = $l -split "`t"; if ($p.Count -ge 2) { $NameCache[$p[0]] = $p[1] } }

Build-Index
$idx = 0
$DeadRe = '^ERROR:.*(unavailable|private|removed|terminated|copyright|not available|no longer)'

# ================================================================== LOOP
foreach ($raw in $Lines) {
    if ($raw -notmatch 'list=([A-Za-z0-9_-]+)') { $S.Skipped++; continue }
    $listId = $Matches[1]
    $idx++
    $url = 'https://www.youtube.com/playlist?list=' + $listId

    $known = ''
    $fields = $raw -split "`t"
    if ($fields.Count -ge 3) { $known = $fields[1].Trim() }
    if (-not $known -and $NameCache.ContainsKey($listId)) { $known = $NameCache[$listId] }
    if (-not $known) { $known = 'playlist n.' + $idx }

    Draw-Progress $idx $Total $known 'lettura da YouTube...'
    $metaF = Join-Path $Work 'meta.txt'; $errF = Join-Path $Work 'meta.err'
    [void](Run-Yt ($MetaOpts + @('--flat-playlist', '--print', "%(playlist_title)s`t%(id)s`t%(title)s", $url)) $metaF $errF)
    $meta = @(Read-Lines $metaF | Where-Object { $_ -match "`t" })
    $title = ''
    if ($meta.Count -gt 0) { $title = ($meta[0] -split "`t")[0] }

    if (-not $title -or $title -eq 'NA') {
        Log ('playlist non raggiungibile: «' + $known + '» ' + $url)
        $S.Unreach++
        $Report.Add([pscustomobject]@{ St = 'UNREACH'; Name = $known; Yt = '-'; Mac = '-'; Miss = 0 })
        continue
    }

    $S.Valid++
    $NameCache[$listId] = $title
    $NamesOut.Add($listId + "`t" + $title)

    $Cur = New-Object 'System.Collections.Generic.HashSet[string]'
    $Titles = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($m in $meta) {
        $p = $m -split "`t"
        if ($p.Count -ge 2 -and $p[1] -cmatch '^[A-Za-z0-9_-]{11}$') {
            [void]$Cur.Add($p[1])
            if ($p.Count -ge 3) { $Titles[$p[1]] = $p[2] }
        }
    }
    $ytCount = $Cur.Count
    $F = Join-Path $Dest (Safe-Name $title)
    New-Item -ItemType Directory -Force -Path $F | Out-Null
    Log ('sync: ' + $title + ' (' + $ytCount + ' brani su YouTube)')

    if ($ytCount -eq 0) {
        Log ('AVVISO "' + $title + '": letti 0 brani — playlist saltata per sicurezza.')
        $Report.Add([pscustomobject]@{ St = 'WARN'; Name = $title; Yt = '?'; Mac = (Ids-InFolder $F).Count; Miss = 0 })
        continue
    }

    $Dead = New-Object 'System.Collections.Generic.HashSet[string]'

    # FASE 1 — completa da altre cartelle (collegamento) o da _RIMOSSI
    $have = Ids-InFolder $F
    $miss = @($Cur | Where-Object { -not $have.Contains($_) })
    if ($miss.Count -gt 0) {
        Draw-Progress $idx $Total $title 'controllo brani gia'' presenti in altre playlist...'
        foreach ($id in $miss) {
            $src = Find-Source $id $F
            if (-not $src) { continue }
            $leaf = Split-Path -Leaf $src
            if (Under $src $Removed) {
                try { Move-Item -LiteralPath $src -Destination (Join-Path $F $leaf) -Force -ErrorAction Stop
                      $S.Restored++; Log ('   ripristinato da _RIMOSSI: ' + $leaf) } catch {}
            } else {
                if (Link-OrCopy $src (Join-Path $F $leaf)) { $S.Cloned++; Log ('   copiato da altra playlist: ' + $leaf) }
            }
        }
    }

    # FASE 2 — scarica solo i mancanti
    $have = Ids-InFolder $F
    $miss = @($Cur | Where-Object { -not $have.Contains($_) })
    if ($miss.Count -gt 0) {
        Draw-Progress $idx $Total $title ('scarico ' + $miss.Count + ' brani...')
        $urlsF = Join-Path $Work 'urls.txt'
        [IO.File]::WriteAllLines($urlsF, [string[]]($miss | ForEach-Object { 'https://www.youtube.com/watch?v=' + $_ }))
        $before = $have.Count
        $outF = Join-Path $Work 'dl.out'; $errF = Join-Path $Work 'dl.err'
        $dlArgs = @('--quiet', '--no-warnings', '--ignore-errors', '--no-overwrites') + $NetOpts + @(
            '--ffmpeg-location', $Bin, '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0',
            '--embed-thumbnail', '--add-metadata', '-P', $F, '-o', '%(title)s [%(id)s].%(ext)s', '-a', $urlsF)
        [void](Run-Yt $dlArgs $outF $errF)
        $after = (Ids-InFolder $F).Count
        $new = [Math]::Max(0, $after - $before)
        $S.New += $new
        if ($new -gt 0) { Log ('nuovi in "' + $title + '": ' + $new) }

        $errs = @(Read-Lines $errF | Where-Object { $_ -like 'ERROR:*' })
        if ($errs.Count -gt 0) {
            $dDead = @($errs | Where-Object { $_ -match $DeadRe }).Count
            $dBot  = @($errs | Where-Object { $_ -match '^ERROR:.*(sign in to confirm|not a bot|confirm you)' }).Count
            $d403  = @($errs | Where-Object { $_ -match '^ERROR:.*(403|forbidden)' }).Count
            $d429  = @($errs | Where-Object { $_ -match '^ERROR:.*(429|too many requests)' }).Count
            $S.Dead += $dDead; $S.Bot += $dBot; $S.E403 += $d403; $S.E429 += $d429; $S.DlErr += $errs.Count
            foreach ($er in $errs) { if ($er -match $DeadRe -and $er -cmatch '^ERROR: \[[^\]]*\] ([A-Za-z0-9_-]{11}):') { [void]$Dead.Add($Matches[1]) } }
            Log ('   ' + $errs.Count + ' non scaricabili in "' + $title + '" (morti:' + $dDead + ' signin:' + $dBot + ' 403:' + $d403 + ' 429:' + $d429 + ')')
            foreach ($er in ($errs | Select-Object -First 40)) { LogRaw ('     ' + $er) }
        }

        # secondo tentativo sui bloccati (non morti)
        foreach ($client in $RetryClients) {
            $have = Ids-InFolder $F
            $retry = @($Cur | Where-Object { -not $have.Contains($_) -and -not $Dead.Contains($_) })
            if ($retry.Count -eq 0) { break }
            Draw-Progress $idx $Total $title ('secondo tentativo per ' + $retry.Count + ' brani...')
            [IO.File]::WriteAllLines($urlsF, [string[]]($retry | ForEach-Object { 'https://www.youtube.com/watch?v=' + $_ }))
            $b2 = $have.Count
            $errF2 = Join-Path $Work 'dl2.err'
            $rArgs = @('--quiet', '--no-warnings', '--ignore-errors', '--no-overwrites') + $NetOpts + @(
                '--extractor-args', ('youtube:player_client=' + $client),
                '--ffmpeg-location', $Bin, '--extract-audio', '--audio-format', 'mp3', '--audio-quality', '0',
                '--embed-thumbnail', '--add-metadata', '-P', $F, '-o', '%(title)s [%(id)s].%(ext)s', '-a', $urlsF)
            [void](Run-Yt $rArgs $outF $errF2)
            $got = [Math]::Max(0, (Ids-InFolder $F).Count - $b2)
            $S.RetryOk += $got; $S.New += $got
            Log ('   secondo tentativo (' + $client + ') in "' + $title + '": recuperati ' + $got + ' su ' + $retry.Count)
            foreach ($er in (Read-Lines $errF2 | Where-Object { $_ -like 'ERROR:*' } | Select-Object -First 5)) { LogRaw ('     [' + $client + '] ' + $er) }
        }
    }

    # FASE 3 — brani tolti dalla playlist
    Draw-Progress $idx $Total $title 'riordino...'
    Build-Index
    Get-ChildItem -LiteralPath $F -File -Filter '*.mp3' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -cmatch $IdRe) {
            $id = $Matches[1]
            if (-not $Cur.Contains($id)) {
                $other = Other-Copy $id $F
                if ($other) {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                          $S.DupDel++; Log ('   tolto doppione (resta in ' + (Split-Path -Leaf (Split-Path -Parent $other)) + '): ' + $_.Name) } catch {}
                } else {
                    New-Item -ItemType Directory -Force -Path $Removed | Out-Null
                    try { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $Removed $_.Name) -Force -ErrorAction Stop
                          $S.Removed++; Log ('   rimosso da "' + $title + '" -> _RIMOSSI: ' + $_.Name) } catch {}
                }
            }
        }
    }
    Build-Index

    # riga tabella
    $have = Ids-InFolder $F
    $macCount = @($Cur | Where-Object { $have.Contains($_) }).Count
    $missNow = @($Cur | Where-Object { -not $have.Contains($_) })
    $missDead = @($missNow | Where-Object { $Dead.Contains($_) }).Count
    foreach ($id in $missNow) {
        $t = ''; if ($Titles.ContainsKey($id)) { $t = $Titles[$id] }
        $why = 'non scaricato per ora'
        if ($Dead.Contains($id)) {
            if (Is-GoneTitle $t) { $why = 'cancellato o privato'; $kind = 'G'; $S.MissGone++ }
            else { $why = 'bloccato (spesso solo in Italia)'; $kind = 'B'; $S.MissBlocked++ }
            $DeadList.Add([pscustomobject]@{ Playlist = $title; Title = $t; Id = $id; Kind = $kind })
        }
        Log ('   manca in "' + $title + '": https://youtu.be/' + $id + '  (' + $why + ')  ' + $t)
    }
    $S.MissDead += $missDead
    $S.MissOther += ($missNow.Count - $missDead)
    $st = 'OK'
    if ($missNow.Count -gt 0) { if ($missNow.Count -eq $missDead) { $st = 'DEAD' } else { $st = 'WARN' } }
    $Report.Add([pscustomobject]@{ St = $st; Name = $title; Yt = $ytCount; Mac = $macCount; Miss = $missNow.Count })
}

# cache nomi
try {
    $nl = foreach ($k in $NameCache.Keys) { $k + "`t" + $NameCache[$k] }
    [IO.File]::WriteAllLines($NamesCache, [string[]]$nl, $Utf8)
} catch {}

# ============================================================ RIEPILOGO
$dur = (Get-Date) - $Start
$durTxt = '{0}m{1}s' -f [int][Math]::Floor($dur.TotalMinutes), $dur.Seconds
$other = [Math]::Max(0, $S.DlErr - $S.Dead - $S.Bot - $S.E403 - $S.E429)
$Summary = 'Sync ' + $AppVersion + ' [PC Windows] (yt-dlp ' + $YtVer + ') — playlist:' + $S.Valid +
    ', nuovi:' + $S.New + ' (di cui al 2o tentativo:' + $S.RetryOk + '), copiati_da_altre:' + $S.Cloned +
    ', ripristinati:' + $S.Restored + ', rimossi:' + $S.Removed + ', doppioni_tolti:' + $S.DupDel +
    ', mancanti:' + ($S.MissDead + $S.MissOther) + ' [morti:' + $S.MissDead + ' (cancellati:' + $S.MissGone + ' bloccati:' + $S.MissBlocked + ') altri:' + $S.MissOther + ']' +
    ', errori_download:' + $S.DlErr + ' [morti:' + $S.Dead + ' signin:' + $S.Bot + ' 403:' + $S.E403 + ' 429:' + $S.E429 + ' altro:' + $other + ']' +
    ', righe_saltate:' + $S.Skipped + ', non_raggiungibili:' + $S.Unreach + $OfflineNote + ' (' + $durTxt + ')'
if ($S.Unreach -gt 0 -or $S.MissOther -gt 0) { $Summary = 'ATTENZIONE ' + $Summary }
Log ('durata: ' + $durTxt)
Log ('fine — ' + $Summary)
LogRaw '---- RIEPILOGO PLAYLIST (stato / YouTube / PC / mancanti) ----'
foreach ($r in $Report) { LogRaw ('  [{0,-7}] {1,-30} yt:{2,-4} pc:{3,-4} mancanti:{4}' -f $r.St, $r.Name, $r.Yt, $r.Mac, $r.Miss) }
LogRaw '---------------------------------------------------------------'

# log locale non infinito
try {
    $all = [IO.File]::ReadAllLines($LogFile, [Text.Encoding]::UTF8)
    if ($all.Count -gt $LogKeep) { [IO.File]::WriteAllLines($LogFile, [string[]]($all | Select-Object -Last $LogKeep), $Utf8) }
} catch {}

# invio a Stefano
if ($EndpointUrl -match '^https') {
    $detail = ($RunLog -join "`n")
    if ($detail.Length -gt $DetailMax) {
        $head = $detail.Substring(0, [int]($DetailMax / 3))
        $tail = $detail.Substring($detail.Length - [int]($DetailMax * 2 / 3 - 300))
        $detail = $head + "`n`n... [log tagliato: " + $detail.Length + " caratteri in tutto, qui sotto la parte finale; completo sul PC in youtube_sync_pc.log] ...`n`n" + $tail
    }
    $f = New-Object System.Collections.Specialized.OrderedDictionary
    $f['summary'] = $Summary; $f['detail'] = $detail; $f['names'] = ($NamesOut -join "`n")
    try { [void](Post-Form $EndpointUrl $f); Log 'stato inviato a Stefano' } catch { Log 'AVVISO invio stato non riuscito' }
}

# ========================================================= SCHERMATA FINALE
Draw-Header
if ($S.Valid -eq 0 -and $S.Unreach -gt 0) {
    Write-Host '      YouTube non risponde in questo momento.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '      Non ho toccato nessun file.'
    Write-Host '      Riprova tra un po''. Se succede di nuovo, avvisa Stefano.'
    Finish 0
}
if ($S.MissOther -gt 0 -or $S.Unreach -gt 0) {
    Write-Host '      Fatto   (con qualche avviso, vedi sotto)' -ForegroundColor Yellow
} else {
    Write-Host '      Tutto sincronizzato!' -ForegroundColor Green
}
Write-Host ''
Write-Host ('      {0,-30} {1,7} {2,5}   {3}' -f 'Playlist', 'YouTube', 'PC', 'Stato')
Write-Host '   ---------------------------------------------------------------' -ForegroundColor DarkGray
foreach ($r in $Report) {
    $n = [string]$r.Name; if ($n.Length -gt 28) { $n = $n.Substring(0, 27) + '~' }
    Write-Host ('      {0,-30} {1,7} {2,5}   ' -f $n, $r.Yt, $r.Mac) -NoNewline
    switch ($r.St) {
        'OK'      { Write-Host 'completa' -ForegroundColor Green }
        'DEAD'    { Write-Host 'completa*' -ForegroundColor Green }
        'UNREACH' { Write-Host 'non trovata' -ForegroundColor DarkGray }
        default   { Write-Host ('mancano ' + $r.Miss) -ForegroundColor Yellow }
    }
}
Write-Host '   ---------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''
Write-Host ('      Brani nuovi scaricati:            ' + $S.New)
if ($S.Cloned -gt 0) { Write-Host ('      Brani aggiunti da altre playlist: ' + $S.Cloned) }
if (@($Report | Where-Object { $_.St -eq 'DEAD' }).Count -gt 0) {
    Write-Host ''
    Write-Host '      completa* = mancano solo brani non disponibili su YouTube' -ForegroundColor Gray
}
$LinksPage = ''
if ($DeadList.Count -gt 0) {
    Write-Host ''
    Write-Host ('      Brani non disponibili su YouTube:  ' + $DeadList.Count)
    foreach ($grp in @(@('G', 'CANCELLATI O PRIVATI', 'Non tornano piu''. Se vuoi, toglili dalla playlist.'),
                       @('B', 'BLOCCATI (spesso solo in Italia)', 'Cerca un''altra versione dello stesso brano e aggiungila alla playlist.'))) {
        $items = @($DeadList | Where-Object { $_.Kind -eq $grp[0] })
        if ($items.Count -eq 0) { continue }
        Write-Host ''
        Write-Host ('      ' + $grp[1] + ':  ' + $items.Count) -ForegroundColor Yellow
        Write-Host ('      ' + $grp[2]) -ForegroundColor Gray
        $last = ''
        foreach ($d in $items) {
            if ($d.Playlist -ne $last) { Write-Host ''; Write-Host ('         ' + $d.Playlist); $last = $d.Playlist }
            $t = $d.Title; if (Is-GoneTitle $t) { $t = '(titolo non piu'' disponibile)' }
            if ($t.Length -gt 60) { $t = $t.Substring(0, 59) + '~' }
            Write-Host ('           - ' + $t)
            if ($d.Kind -eq 'G') { Write-Host ('             https://youtu.be/' + $d.Id) -ForegroundColor Cyan }
            else { Write-Host ('      ' + (Search-Url $d.Title 32)) -ForegroundColor Cyan }
        }
    }
    # pagina con i link cliccabili
    try {
        $enc = { param($x) [System.Net.WebUtility]::HtmlEncode([string]$x) }
        $h = New-Object System.Text.StringBuilder
        [void]$h.Append('<!doctype html><html lang="it"><head><meta charset="utf-8"><title>YouTubeSync - brani non disponibili</title>')
        [void]$h.Append('<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:760px;margin:30px auto;padding:0 16px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:28px}h3{font-size:15px;color:#555;margin:18px 0 6px}li{margin:6px 0}a{color:#c00}small{color:#777}</style></head><body>')
        [void]$h.Append('<h1>Brani non disponibili su YouTube (' + $DeadList.Count + ')</h1><p><small>Aggiornato: ' + (Get-Date -Format 'dd/MM/yyyy HH:mm') + '</small></p>')
        foreach ($grp in @(@('G', 'Cancellati o privati', 'Non tornano pi&ugrave;. Se vuoi, toglili dalla playlist su youtube.com.', 'apri il video'),
                           @('B', 'Bloccati (spesso solo in Italia)', 'Cerca un&#39;altra versione dello stesso brano e aggiungila alla playlist.', 'cerca su YouTube'))) {
            $items = @($DeadList | Where-Object { $_.Kind -eq $grp[0] })
            if ($items.Count -eq 0) { continue }
            [void]$h.Append('<h2>' + $grp[1] + ' (' + $items.Count + ')</h2><p>' + $grp[2] + '</p>')
            $last = ''
            foreach ($d in $items) {
                if ($d.Playlist -ne $last) { if ($last) { [void]$h.Append('</ul>') }; [void]$h.Append('<h3>' + (& $enc $d.Playlist) + '</h3><ul>'); $last = $d.Playlist }
                $t = $d.Title; if (Is-GoneTitle $t) { $t = '(titolo non pi&ugrave; disponibile)' } else { $t = & $enc $t }
                if ($d.Kind -eq 'G') { $u = 'https://youtu.be/' + $d.Id } else { $u = Search-Url $d.Title 0 }
                [void]$h.Append('<li>' + $t + ' &mdash; <a href="' + (& $enc $u) + '" target="_blank">' + $grp[3] + '</a></li>')
            }
            [void]$h.Append('</ul>')
        }
        [void]$h.Append('</body></html>')
        $LinksPage = Join-Path $Dest 'brani_non_disponibili.html'
        [IO.File]::WriteAllText($LinksPage, $h.ToString(), $Utf8)
    } catch { $LinksPage = '' }
}
if ($S.MissOther -gt 0) {
    Write-Host ''
    Write-Host ('      Brani non scaricati per ora:  ' + $S.MissOther) -ForegroundColor Yellow
    Write-Host '      Riprovo da solo al prossimo avvio. Se restano'
    Write-Host '      per qualche giorno, avvisa Stefano.'
}
if ($S.Unreach -gt 0) {
    Write-Host ''
    Write-Host ('      Playlist non trovate su YouTube:  ' + $S.Unreach) -ForegroundColor Yellow
    Write-Host '      Sono state cancellate o rese private.'
    Write-Host '      Se non ti servono piu'', toglile con "Gestisci playlist";'
    Write-Host '      se ti servono, su YouTube mettile "Non in elenco".'
}
Write-Host ''
if ($LinksPage) {
    Write-Host '      Per aprire i link: scrivi L e premi INVIO.' -ForegroundColor Green
    Write-Host '      Per chiudere: premi solo INVIO.' -ForegroundColor Green
    Write-Host ''
    $ans = Read-Host '     '
    if ($ans -match '^\s*[lL]') { try { Start-Process $LinksPage } catch {} }
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}
Write-Host '      Puoi chiudere questa finestra.' -ForegroundColor Green
Finish 0
