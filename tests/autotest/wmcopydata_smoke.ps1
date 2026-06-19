# WM_COPYDATA editor-sync smoke test for the graph viewer.
# Launches the viewer on a DB, finds its window, sends a CD_CENTER_SYMBOL
# message with (a) a real unit name and (b) a bogus name, and asserts the
# process survives both (no AV / no crash). Exercises the receiving half of
# the editor-sync wiring in isolation -- the plugin is the real sender.
$ErrorActionPreference = 'Stop'

$exe = 'C:\Projects\Delphi-RAG-Lint-Graph\bin\Win32\drag_lint_graph.exe'
$db  = 'C:\Projects\DB\ORM3\drag-lint.sqlite'
$realSym = 'uPLANLIST'          # a unit known to exist in the ORM3 index
$bogusSym = 'ZZ_NoSuchSymbol_QQ'
$CD_CENTER_SYMBOL = [Convert]::ToUInt32('DA61C000', 16)

if (-not (Test-Path $exe)) { throw "viewer exe not found: $exe" }
if (-not (Test-Path $db))  { throw "db not found: $db" }

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CD {
  [StructLayout(LayoutKind.Sequential)]
  public struct COPYDATASTRUCT { public IntPtr dwData; public int cbData; public IntPtr lpData; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")]
  public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, ref COPYDATASTRUCT lParam);
  public const uint WM_COPYDATA = 0x004A;
  // Find the viewer's form window (class TfrmMain) owned by the given PID -- the
  // same strategy the IDE plugin uses (it spawned the viewer, so it has the PID).
  public static IntPtr FormForPid(uint want) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h,l)=>{
      uint p; GetWindowThreadProcessId(h, out p);
      if (p==want && IsWindowVisible(h)) {
        var c=new StringBuilder(64); GetClassName(h,c,64);
        if (c.ToString()=="TfrmMain") { found=h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static IntPtr Send(IntPtr hWnd, uint magic, string s) {
    byte[] bytes = System.Text.Encoding.ASCII.GetBytes(s);   // ANSI payload
    IntPtr buf = Marshal.AllocHGlobal(bytes.Length);
    Marshal.Copy(bytes, 0, buf, bytes.Length);
    COPYDATASTRUCT cds = new COPYDATASTRUCT();
    cds.dwData = (IntPtr)magic; cds.cbData = bytes.Length; cds.lpData = buf;
    try { return SendMessage(hWnd, WM_COPYDATA, IntPtr.Zero, ref cds); }
    finally { Marshal.FreeHGlobal(buf); }
  }
}
"@

$p = Start-Process -FilePath $exe -ArgumentList @('--db', $db) -PassThru
try {
  # Wait for the viewer's form window (class TfrmMain) owned by our PID.
  $hWnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 50 -and $hWnd -eq [IntPtr]::Zero; $i++) {
    Start-Sleep -Milliseconds 200
    $hWnd = [CD]::FormForPid([uint32]$p.Id)
  }
  if ($hWnd -eq [IntPtr]::Zero) { throw 'viewer form window (class TfrmMain) not found for PID' }
  Start-Sleep -Milliseconds 800   # let RunLoad finish building the graph

  $r1 = [CD]::Send($hWnd, $CD_CENTER_SYMBOL, $realSym)
  Start-Sleep -Milliseconds 300
  if ($p.HasExited) { throw "viewer crashed after valid symbol (exit $($p.ExitCode))" }

  $r2 = [CD]::Send($hWnd, $CD_CENTER_SYMBOL, $bogusSym)
  Start-Sleep -Milliseconds 300
  if ($p.HasExited) { throw "viewer crashed after bogus symbol (exit $($p.ExitCode))" }

  # A wrong magic must be ignored (no crash).
  $r3 = [CD]::Send($hWnd, [uint32]0x12345678, $realSym)
  Start-Sleep -Milliseconds 200
  if ($p.HasExited) { throw "viewer crashed after wrong-magic message (exit $($p.ExitCode))" }

  Write-Host "PASS: viewer alive through valid/bogus/wrong-magic WM_COPYDATA."
  Write-Host ("  valid  -> SendMessage result = {0} (expect 1 = resolved)" -f $r1)
  Write-Host ("  bogus  -> SendMessage result = {0} (expect 0 = unresolved)" -f $r2)
  Write-Host ("  wrong-magic -> result = {0} (expect 0 = ignored)" -f $r3)
  if ("$r1" -ne '1') { Write-Warning "valid symbol did not resolve (result != 1) -- check resolution or DB content" }
}
finally {
  if (-not $p.HasExited) { $p.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 500 }
  if (-not $p.HasExited) { $p.Kill() }
}
