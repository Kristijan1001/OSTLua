# ostlua_grab.ps1 — read the clipboard, optionally auto-copying (and closing) a SteamDB window.
# -Auto 1 : clear the clipboard to a sentinel, then find the SteamDB window, post a click
#           into its render-widget (focuses the page, no mouse movement), Ctrl+A / Ctrl+C,
#           and accept the result ONLY if the clipboard actually changed to something with
#           manifest IDs (so stale IDs from a previous game can't false-succeed). Then close.
# -Auto 0 : just read whatever is already on the clipboard.
param(
    [Parameter(Mandatory=$true)][string]$ResultFile,
    [int]$Auto = 0,
    [string]$Title = ""
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
                    if ($sb.ToString() -like "*SteamDB*") { $script:top = $h; return $false }
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

        $sentinel = "HUBCAP_" + [Guid]::NewGuid().ToString("N")
        Set-Clipboard -Value $sentinel
        $WM_LBUTTONDOWN = 0x0201; $WM_LBUTTONUP = 0x0202
        $lp = [IntPtr]((300 * 65536) + 60)

        for ($i = 0; $i -lt 8; $i++) {
            $top = Find-Top
            if ($top -ne [IntPtr]::Zero) {
                $target = Find-RenderWidget $top
                if ($target -eq [IntPtr]::Zero) { $target = $top }
                if ($Title) { try { $sh.AppActivate($Title) | Out-Null } catch {} }
                Start-Sleep -Milliseconds 150
                try {
                    [HW]::PostMessage($target, $WM_LBUTTONDOWN, [IntPtr]1, $lp) | Out-Null
                    [HW]::PostMessage($target, $WM_LBUTTONUP,   [IntPtr]0, $lp) | Out-Null
                } catch {}
                Start-Sleep -Milliseconds 120
                $sh.SendKeys("^a")
                Start-Sleep -Milliseconds 110
                $sh.SendKeys("^c")
                Start-Sleep -Milliseconds 180
                $c = Get-Clipboard -Raw
                if ($c -ne $sentinel -and $c -match "\d{12,}") { $clip = $c; break }
            }
            Start-Sleep -Milliseconds 300
        }

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
