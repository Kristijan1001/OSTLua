# ostlua_grab.ps1 — read the clipboard, optionally auto-copying (and closing) a SteamDB window.
# -Auto 1 : clear the clipboard to a sentinel, then find the SteamDB window, post a click
#           into its render-widget (focuses the page, no mouse movement), Ctrl+A / Ctrl+C,
#           and accept the result ONLY if the clipboard actually changed to something with
#           manifest IDs (so stale IDs from a previous game can't false-succeed). Then close.
# -Auto 0 : just read whatever is already on the clipboard.
param(
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [int]$Auto = 0,
    [string]$Title = "",
    # What a good copy looks like for the page being read. Depot manifest pages
    # show 12+ digit ids as text; SteamDB build pages only carry the manifest in
    # each depot link, so there we look for changeid=M: in the clipboard's HTML
    # flavor instead. Without this the loop below never accepted the copy and
    # kept re-selecting the page eight times.
    [string]$Accept = "\d{12,}"
)

$clip = ""
try {
    if ($Auto -eq 1) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class HW {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
        $sh = New-Object -ComObject WScript.Shell

        function Find-Top {
            $script:top = [IntPtr]::Zero
            $cb = [HW+EnumProc] {
                param($h, $l)
                if ([HW]::IsWindowVisible($h)) {
                    $sb = New-Object System.Text.StringBuilder 512
                    [HW]::GetWindowText($h, $sb, 512) | Out-Null
                    if ($sb.ToString() -like $script:want) { $script:top = $h; return $false }
                }
                return $true
            }
            try { [HW]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null } catch {}
            return $script:top
        }
        function Find-RenderWidget([IntPtr]$parent) {
            $script:rw = [IntPtr]::Zero
            $cb = [HW+EnumProc] {
                param($h, $l)
                $sb = New-Object System.Text.StringBuilder 256
                [HW]::GetClassName($h, $sb, 256) | Out-Null
                if ($sb.ToString() -like "*RenderWidget*") { $script:rw = $h }
                return $true
            }
            try { [HW]::EnumChildWindows($parent, $cb, [IntPtr]::Zero) | Out-Null } catch {}
            return $script:rw
        }

        # Several SteamDB tabs can be open at once (the build LIST tab is still
        # around when we open a build page). Matching "*SteamDB*" grabbed
        # whichever came first - usually the wrong one - so callers pass a
        # distinguishing piece of the title instead.
        $script:want = if ($Title) { "*" + $Title + "*" } else { "*SteamDB*" }

        $sentinel = "HUBCAP_" + [Guid]::NewGuid().ToString("N")
        Set-Clipboard -Value $sentinel
        $WM_LBUTTONDOWN = 0x0201; $WM_LBUTTONUP = 0x0202

        # Where to click to focus the page WITHOUT hitting anything.
        # The old fixed point (x=60, y=300) landed on the date link in a build
        # page's metadata row, which navigates to the app's Patches page - so the
        # helper kept copying the wrong page. Aim at the far-left margin instead,
        # which is page background on every SteamDB layout.
        function Get-SafePoint([IntPtr]$h) {
            $r = New-Object HW+RECT
            $y = 300
            try { if ([HW]::GetClientRect($h, [ref]$r)) { $y = [Math]::Max(80, [int](($r.B - $r.T) / 2)) } } catch {}
            return [IntPtr](($y * 65536) + 2)
        }

        $bestText = ""; $bestHtml = ""; $attempts = 0; $matched = $false
        for ($i = 0; $i -lt 3; $i++) {
            $attempts = $i + 1
            $top = Find-Top
            if ($top -ne [IntPtr]::Zero) {
                $target = Find-RenderWidget $top
                if ($target -eq [IntPtr]::Zero) { $target = $top }
                if ($Title) { try { $sh.AppActivate($Title) | Out-Null } catch {} }
                Start-Sleep -Milliseconds 150
                # First try focus alone - a freshly opened tab already has focus,
                # so no click is needed and nothing can be activated by mistake.
                # Only fall back to clicking (on the safe margin) if that failed.
                if ($i -gt 0) {
                    $lp = Get-SafePoint $target
                    try {
                        [HW]::PostMessage($target, $WM_LBUTTONDOWN, [IntPtr]1, $lp) | Out-Null
                        [HW]::PostMessage($target, $WM_LBUTTONUP,   [IntPtr]0, $lp) | Out-Null
                    } catch {}
                    Start-Sleep -Milliseconds 120
                }
                $sh.SendKeys("^a")
                Start-Sleep -Milliseconds 110
                $sh.SendKeys("^c")
                Start-Sleep -Milliseconds 180
                $c = Get-Clipboard -Raw
                # Also grab the HTML flavor: links (and therefore manifest ids)
                # survive there, and lazy-loaded rows do not matter because the
                # depot headings are in the markup from the start.
                $h = ""
                try { $h = (Get-Clipboard -TextFormatType Html) -join "`n" } catch {}
                # Only trust HTML once the text really changed, otherwise we
                # could accept a stale HTML flavor from an earlier copy.
                if ($c -ne $sentinel) {
                    if ($c -and $c.Length -gt $bestText.Length) { $bestText = $c }
                    if ($h -and $h.Length -gt $bestHtml.Length) { $bestHtml = $h }
                    if ($h -and $h -match $Accept) { $clip = $h; $matched = $true; break }
                    if ($c -match $Accept)         { $clip = $c; $matched = $true; break }
                }
            }
            Start-Sleep -Milliseconds 300
        }

        # Never leave empty-handed: if the accept test never matched, hand back
        # the richest capture anyway so the caller can parse (or report) it
        # instead of us re-selecting the page over and over.
        if (-not $matched) {
            if ($bestHtml.Length -gt 0) { $clip = $bestHtml } elseif ($bestText.Length -gt 0) { $clip = $bestText }
        }

        try {
            $dbg = @()
            $dbg += "attempts=$attempts matched=$matched"
            $dbg += "accept=$Accept"
            $dbg += "textLen=" + $bestText.Length + " htmlLen=" + $bestHtml.Length
            $dbg += "textHasAccept=" + ($bestText -match $Accept)
            $dbg += "htmlHasAccept=" + ($bestHtml -match $Accept)
            $dbg += "--- text head ---"
            if ($bestText.Length -gt 0) { $dbg += $bestText.Substring(0, [Math]::Min(600, $bestText.Length)) }
            $dbg += "--- html head ---"
            if ($bestHtml.Length -gt 0) { $dbg += $bestHtml.Substring(0, [Math]::Min(1200, $bestHtml.Length)) }
            [System.IO.File]::WriteAllText("$ResultFile.debug.txt", ($dbg -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
        } catch {}

        $top = Find-Top
        if ($top -ne [IntPtr]::Zero) {
            try { [HW]::PostMessage($top, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null } catch {}  # WM_CLOSE
        }
    }
    else {
        $clip = Get-Clipboard -Raw
    }
    if ($null -eq $clip) { $clip = "" }
} catch { $clip = "" }

[System.IO.File]::WriteAllText($ResultFile, $clip, (New-Object System.Text.UTF8Encoding $false))
