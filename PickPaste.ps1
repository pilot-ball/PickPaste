param(
    [switch]$debug
)
$ErrorActionPreference = "Stop"
$ProductName = "PickPaste"

function Get-ExecutionRoot {
    if (-not [string]::IsNullOrEmpty($PSScriptRoot) -and $PSScriptRoot -ne ".") { return $PSScriptRoot }
    if (-not [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)) { return Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not [string]::IsNullOrEmpty($PSCommandPath)) { return Split-Path -Parent $PSCommandPath }
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -and $exePath.EndsWith(".exe")) { return Split-Path -Parent $exePath }
    } catch { }
    return (Get-Location).Path
}

$ScriptRoot = Get-ExecutionRoot
$ConfigPath = Join-Path $ScriptRoot "config.ini"

function ConvertTo-BoolValue {
    param([string]$Value, [bool]$DefaultValue)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $DefaultValue }
    switch ($Value.Trim().ToLowerInvariant()) {
        "true"  { return $true }
        "1"     { return $true }
        "yes"   { return $true }
        "on"    { return $true }
        "false" { return $false }
        "0"     { return $false }
        "no"    { return $false }
        "off"   { return $false }
        default { return $DefaultValue }
    }
}

function Read-PickPasteConfig {
    param([string]$Path)
    $config = @{
        EnableKeyboard = $true
        EnableXButton  = $true
        HotkeyCollect  = "Ctrl+Alt+C"
        HotkeyPaste    = "Ctrl+Alt+V"
        HotkeyClear    = "Ctrl+Alt+X"
        HotkeyStatus   = "Ctrl+Alt+Q"
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $config }
    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";") -or $trimmed.StartsWith("[")) { continue }
            $parts = $trimmed.Split("=", 2, [System.StringSplitOptions]::None)
            if ($parts.Count -ne 2) { continue }
            $key = $parts[0].Trim().ToLowerInvariant()
            $value = $parts[1].Trim()

            switch ($key) {
                "enablekeyboard" { $config.EnableKeyboard = ConvertTo-BoolValue $value $config.EnableKeyboard }
                "enablexbutton"  { $config.EnableXButton  = ConvertTo-BoolValue $value $config.EnableXButton }
                "hotkeycollect"  { if (-not [string]::IsNullOrWhiteSpace($value)) { $config.HotkeyCollect = $value } }
                "hotkeypaste"    { if (-not [string]::IsNullOrWhiteSpace($value)) { $config.HotkeyPaste = $value } }
                "hotkeyclear"    { if (-not [string]::IsNullOrWhiteSpace($value)) { $config.HotkeyClear = $value } }
                "hotkeystatus"   { if (-not [string]::IsNullOrWhiteSpace($value)) { $config.HotkeyStatus = $value } }
            }
        }
    } catch {
        Write-Host "`nWARNING: Could not read configuration file. Using default configuration.`nError: $($_.Exception.Message)`n"
    }
    return $config
}

$config = Read-PickPasteConfig -Path $ConfigPath
$EnableKeyboard = [bool]$config.EnableKeyboard
$EnableXButton  = [bool]$config.EnableXButton

$DynamicNamespace = "PickPaste_" + [guid]::NewGuid().ToString("N")

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace $DynamicNamespace
{
    // ==========================================
    // 1. Clipboard Layer
    // ==========================================
    public static class ClipboardManager
    {
        private const uint CF_UNICODETEXT = 13;
        private const uint GMEM_MOVEABLE  = 0x0002;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool OpenClipboard(IntPtr hWndNewOwner);
        [DllImport("user32.dll")]
        private static extern bool CloseClipboard();
        [DllImport("user32.dll")]
        private static extern bool EmptyClipboard();
        [DllImport("user32.dll")]
        private static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32.dll")]
        private static extern IntPtr GetClipboardData(uint uFormat);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();
        [DllImport("kernel32.dll")]
        private static extern IntPtr GlobalLock(IntPtr hMem);
        [DllImport("kernel32.dll")]
        private static extern bool GlobalUnlock(IntPtr hMem);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GlobalFree(IntPtr hMem);

        public static string GetClipboardText()
        {
            for (int attempt = 0; attempt < 10; attempt++)
            {
                if (!OpenClipboard(IntPtr.Zero)) { Thread.Sleep(20); continue; }
                try
                {
                    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
                    IntPtr handle = GetClipboardData(CF_UNICODETEXT);
                    if (handle == IntPtr.Zero) return null;
                    IntPtr pointer = GlobalLock(handle);
                    if (pointer == IntPtr.Zero) return null;
                    try { return Marshal.PtrToStringUni(pointer); }
                    finally { GlobalUnlock(handle); }
                }
                catch { }
                finally { CloseClipboard(); }
                Thread.Sleep(20);
            }
            return null;
        }

        public static bool SetClipboardText(string text)
        {
            if (text == null) return false;
            for (int attempt = 0; attempt < 15; attempt++)
            {
                if (!OpenClipboard(IntPtr.Zero)) { Thread.Sleep(40); continue; }
                IntPtr memory = IntPtr.Zero;
                try
                {
                    if (!EmptyClipboard()) continue;
                    byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
                    memory = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
                    if (memory == IntPtr.Zero) return false;
                    IntPtr pointer = GlobalLock(memory);
                    if (pointer == IntPtr.Zero) { GlobalFree(memory); return false; }
                    try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
                    finally { GlobalUnlock(memory); }
                    IntPtr result = SetClipboardData(CF_UNICODETEXT, memory);
                    if (result == IntPtr.Zero) { GlobalFree(memory); return false; }
                    memory = IntPtr.Zero;
                    return true;
                }
                catch
                {
                    if (memory != IntPtr.Zero) { try { GlobalFree(memory); } catch { } }
                }
                finally { CloseClipboard(); }
                Thread.Sleep(40);
            }
            return false;
        }

        public static string WaitForNewClipboardText(uint previousSequence, int timeoutMilliseconds, Action<string> debugLog)
        {
            Stopwatch stopwatch = Stopwatch.StartNew();
            uint lastReportedSequence = previousSequence;
            while (stopwatch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                uint currentSequence = GetClipboardSequenceNumber();
                if (currentSequence != previousSequence)
                {
                    if (currentSequence != lastReportedSequence)
                    {
                        if (debugLog != null) debugLog("Clipboard sequence changed: " + previousSequence + " -> " + currentSequence);
                        lastReportedSequence = currentSequence;
                    }
                    string text = GetClipboardText();
                    if (!String.IsNullOrEmpty(text)) return text;
                }
                Thread.Sleep(25);
            }
            return null;
        }

        public static void RestoreClipboard(string previousClipboard, uint sequenceBefore, Action<string> debugLog)
        {
            if (previousClipboard == null) return;
            Thread.Sleep(50);
            uint currentSequence = GetClipboardSequenceNumber();
            if (currentSequence != sequenceBefore)
            {
                GetClipboardText();
                uint afterReadSequence = GetClipboardSequenceNumber();
                if (afterReadSequence == currentSequence)
                {
                    if (!SetClipboardText(previousClipboard))
                    {
                        if (debugLog != null) debugLog("WARNING: Could not restore previous clipboard.");
                    }
                    else
                    {
                        if (debugLog != null) debugLog("Previous clipboard restored.");
                    }
                }
                else
                {
                    if (debugLog != null) debugLog("Clipboard changed during restore window; previous clipboard was not restored.");
                }
            }
        }
    }

    // ==========================================
    // 2. Keyboard Layer
    // ==========================================
    public static class KeyboardController
    {
        private const uint VK_CONTROL = 0x11;
        private const uint VK_MENU    = 0x12;
        private const uint VK_C       = 0x43;
        private const uint VK_V       = 0x56;
        private const uint VK_X       = 0x58;
        private const int VK_XBUTTON1 = 0x05;
        private const int VK_XBUTTON2 = 0x06;
        private const uint KEYEVENTF_KEYUP = 0x0002;

        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        public static void WaitForModifierKeys(Action<string> debugLog)
        {
            Stopwatch stopwatch = Stopwatch.StartNew();
            while (stopwatch.ElapsedMilliseconds < 1000)
            {
                bool ctrlDown = (GetAsyncKeyState((int)VK_CONTROL) & 0x8000) != 0;
                bool altDown  = (GetAsyncKeyState((int)VK_MENU) & 0x8000) != 0;
                bool x1Down   = (GetAsyncKeyState(VK_XBUTTON1) & 0x8000) != 0;
                bool x2Down   = (GetAsyncKeyState(VK_XBUTTON2) & 0x8000) != 0;

                if (!ctrlDown && !altDown && !x1Down && !x2Down) return;
                Thread.Sleep(10);
            }
            if (debugLog != null) debugLog("Input buttons remained pressed after 1 second.");
        }

        public static bool SendCtrlC(Action<string> debugLog) { return SendCombination(VK_CONTROL, VK_C, debugLog, "SendCtrlC"); }
        public static bool SendCtrlV(Action<string> debugLog) { return SendCombination(VK_CONTROL, VK_V, debugLog, "SendCtrlV"); }
        public static bool SendCtrlX(Action<string> debugLog) { return SendCombination(VK_CONTROL, VK_X, debugLog, "SendCtrlX"); }

        private static bool SendCombination(uint modifierVk, uint keyVk, Action<string> debugLog, string opName)
        {
            try
            {
                keybd_event((byte)modifierVk, 0, 0, UIntPtr.Zero);
                Thread.Sleep(20);
                keybd_event((byte)keyVk, 0, 0, UIntPtr.Zero);
                Thread.Sleep(20);
                keybd_event((byte)keyVk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                Thread.Sleep(20);
                keybd_event((byte)modifierVk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                return true;
            }
            catch (Exception ex)
            {
                if (debugLog != null) debugLog(opName + " exception: " + ex.Message);
                try
                {
                    keybd_event((byte)keyVk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                    keybd_event((byte)modifierVk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                }
                catch { }
                return false;
            }
        }
    }

    // ==========================================
    // 3. Hotkey Inspection & Management Structs
    // ==========================================
    public enum InspectionStatus
    {
        Ok,
        Failed,
        Disabled
    }

    public struct HotkeyCheckResult
    {
        public string ActionName;
        public string HotkeyStr;
        public InspectionStatus Status;
        public int ErrorCode;
        public string ErrorMessage;
        public string Suggestion;
    }

    public class HotkeyManager
    {
        public const int HOTKEY_ID_COLLECT = 1001;
        public const int HOTKEY_ID_PASTE   = 1002;
        public const int HOTKEY_ID_CLEAR   = 1003;
        public const int HOTKEY_ID_STATUS  = 1004;

        private const uint MOD_ALT      = 0x0001;
        private const uint MOD_CONTROL  = 0x0002;
        private const uint MOD_SHIFT    = 0x0004;
        private const uint MOD_WIN      = 0x0008;
        private const uint MOD_NOREPEAT = 0x4000;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        private readonly Dictionary<int, bool> registeredKeys = new Dictionary<int, bool>();

        public static bool ParseHotkey(string input, out uint modifiers, out uint vk)
        {
            modifiers = MOD_NOREPEAT;
            vk = 0;
            if (string.IsNullOrWhiteSpace(input)) return false;

            string[] parts = input.Split('+');
            for (int i = 0; i < parts.Length; i++)
            {
                string part = parts[i].Trim().ToUpperInvariant();
                if (part == "CTRL" || part == "CONTROL") modifiers |= MOD_CONTROL;
                else if (part == "ALT" || part == "MENU") modifiers |= MOD_ALT;
                else if (part == "SHIFT") modifiers |= MOD_SHIFT;
                else if (part == "WIN" || part == "WINDOWS") modifiers |= MOD_WIN;
                else if (part.Length == 1 && ((part[0] >= 'A' && part[0] <= 'Z') || (part[0] >= '0' && part[0] <= '9')))
                {
                    vk = (uint)part[0];
                }
                else if (part.StartsWith("F"))
                {
                    int fNum;
                    if (int.TryParse(part.Substring(1), out fNum) && fNum >= 1 && fNum <= 12)
                    {
                        vk = (uint)(0x70 + (fNum - 1));
                    }
                }
            }
            return vk != 0;
        }

        private static bool IsSystemReservedShortcut(string hotkeyStr)
        {
            if (string.IsNullOrWhiteSpace(hotkeyStr)) return true;

            string normalized = hotkeyStr.Replace(" ", "").ToUpperInvariant();

            HashSet<string> editingShortcuts = new HashSet<string>
            {
                "CTRL+C", "CTRL+V", "CTRL+X", "CTRL+A", "CTRL+Z", "CTRL+Y", 
                "CTRL+S", "CTRL+P", "CTRL+F", "CTRL+W", "CTRL+N", "CTRL+O"
            };

            if (editingShortcuts.Contains(normalized)) return true;

            HashSet<string> systemShortcuts = new HashSet<string>
            {
                "WIN+L", "WIN+D", "WIN+E", "WIN+R", "WIN+TAB", "WIN+V", "WIN+A", "WIN+I", "WIN+X", "WIN+P",
                "CTRL+ALT+DEL", "CTRL+SHIFT+ESC", "ALT+TAB", "ALT+F4", "ALT+SPACE", "PRINTSCREEN"
            };

            if (systemShortcuts.Contains(normalized)) return true;

            bool hasModifier = normalized.Contains("CTRL") || 
                               normalized.Contains("CONTROL") || 
                               normalized.Contains("ALT") || 
                               normalized.Contains("MENU") || 
                               normalized.Contains("SHIFT") || 
                               normalized.Contains("WIN") || 
                               normalized.Contains("WINDOWS");

            if (!hasModifier) return true;

            return false;
        }

        public static string FindAvailableSuggestions(string baseAction, string originalHotkeyStr)
        {
            string targetKey = GetKeyPart(originalHotkeyStr);
            if (string.IsNullOrWhiteSpace(targetKey)) targetKey = "C";

            string[] candidatePrefixes = new string[]
            {
                "Ctrl+Shift+",
                "Win+Alt+",
                "Ctrl+Alt+",
                "Win+Shift+"
            };

            List<string> availableCandidates = new List<string>();

            foreach (string prefix in candidatePrefixes)
            {
                string candidate = prefix + targetKey;
                if (candidate.Replace(" ", "").Equals(originalHotkeyStr.Replace(" ", ""), StringComparison.OrdinalIgnoreCase))
                    continue;

                HotkeyCheckResult check = InspectHotkey(baseAction, candidate);
                if (check.Status == InspectionStatus.Ok)
                {
                    availableCandidates.Add("'" + candidate + "'");
                    if (availableCandidates.Count >= 2) break;
                }
            }

            if (availableCandidates.Count > 0)
            {
                return "Try using: " + string.Join(" or ", availableCandidates.ToArray());
            }

            return "Try 'Ctrl+Shift+<Key>' or 'Win+Alt+<Key>'.";
        }

        public static HotkeyCheckResult InspectHotkey(string actionName, string hotkeyStr)
        {
            HotkeyCheckResult result = new HotkeyCheckResult();
            result.ActionName = actionName;
            result.HotkeyStr = hotkeyStr;

            if (IsSystemReservedShortcut(hotkeyStr))
            {
                result.Status = InspectionStatus.Failed;
                result.ErrorCode = -2;
                result.ErrorMessage = "Reserved system shortcut";
                result.Suggestion = FindAvailableSuggestions(actionName, hotkeyStr);
                return result;
            }

            uint modifiers, vk;
            if (!ParseHotkey(hotkeyStr, out modifiers, out vk))
            {
                result.Status = InspectionStatus.Failed;
                result.ErrorCode = -1;
                result.ErrorMessage = "Invalid hotkey format";
                result.Suggestion = "Use 'Ctrl+Alt+Key', 'Ctrl+Shift+Key', or 'Win+Key'.";
                return result;
            }

            int dummyId = 9999;
            bool success = RegisterHotKey(IntPtr.Zero, dummyId, modifiers, vk);
            if (success)
            {
                UnregisterHotKey(IntPtr.Zero, dummyId);
                result.Status = InspectionStatus.Ok;
                result.ErrorCode = 0;
                result.ErrorMessage = string.Empty;
                result.Suggestion = string.Empty;
            }
            else
            {
                result.Status = InspectionStatus.Failed;
                result.ErrorCode = Marshal.GetLastWin32Error();
                if (result.ErrorCode == 1409)
                {
                    result.ErrorMessage = "Occupied by system or another app";
                    result.Suggestion = FindAvailableSuggestions(actionName, hotkeyStr);
                }
                else
                {
                    result.ErrorMessage = "Rejected by system (Error " + result.ErrorCode + ")";
                    result.Suggestion = FindAvailableSuggestions(actionName, hotkeyStr);
                }
            }
            return result;
        }

        private static string GetKeyPart(string hotkeyStr)
        {
            string[] parts = hotkeyStr.Split('+');
            return parts[parts.Length - 1].Trim();
        }

        public bool RegisterCustom(int id, string hotkeyStr, Action<string> debugLog)
        {
            if (IsSystemReservedShortcut(hotkeyStr))
            {
                if (debugLog != null) debugLog("ERROR: Refused to register system reserved shortcut: " + hotkeyStr);
                return false;
            }

            uint modifiers, vk;
            if (!ParseHotkey(hotkeyStr, out modifiers, out vk))
            {
                if (debugLog != null) debugLog("ERROR: Invalid hotkey format: " + hotkeyStr);
                return false;
            }

            bool success = RegisterHotKey(IntPtr.Zero, id, modifiers, vk);
            registeredKeys[id] = success;

            if (debugLog != null) debugLog("Hotkey [" + hotkeyStr + "] registration: " + success);
            if (!success && debugLog != null)
            {
                int error = Marshal.GetLastWin32Error();
                debugLog("RegisterHotKey error code: " + error);
            }
            return success;
        }

        public void UnregisterAll(Action<string> debugLog)
        {
            foreach (var kvp in registeredKeys)
            {
                if (kvp.Value)
                {
                    try { UnregisterHotKey(IntPtr.Zero, kvp.Key); }
                    catch (Exception ex)
                    {
                        if (debugLog != null) debugLog("Hotkey cleanup exception: " + ex.Message);
                    }
                }
            }
            registeredKeys.Clear();
        }
    }

    // ==========================================
    // 4. Mouse Hook Layer
    // ==========================================
    public class MouseHook
    {
        private const int WH_MOUSE_LL     = 14;
        private const int WM_XBUTTONDOWN  = 0x020B;
        private const int WM_XBUTTONUP    = 0x020C;
        private const int XBUTTON1        = 0x0001;
        private const int XBUTTON2        = 0x0002;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public POINT pt;
            public uint mouseData;
            public uint flags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string lpModuleName);

        private IntPtr hookId = IntPtr.Zero;
        private LowLevelMouseProc proc;
        private readonly Action<string> onActionTriggered;
        private readonly Action<string> debugLog;

        public MouseHook(Action<string> onActionTriggered, Action<string> debugLog)
        {
            this.onActionTriggered = onActionTriggered;
            this.debugLog = debugLog;
        }

        public bool Install()
        {
            try
            {
                proc = HookCallback;
                hookId = SetWindowsHookEx(WH_MOUSE_LL, proc, GetModuleHandle(null), 0);
                if (hookId == IntPtr.Zero)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (debugLog != null)
                    {
                        debugLog("ERROR: Mouse hook installation failed. Windows error code: " + error);
                    }
                    return false;
                }
                if (debugLog != null) debugLog("Low-level mouse hook installed.");
                return true;
            }
            catch (Exception ex)
            {
                if (debugLog != null) debugLog("Mouse hook exception: " + ex.Message);
                return false;
            }
        }

        public void Uninstall()
        {
            try
            {
                if (hookId != IntPtr.Zero)
                {
                    UnhookWindowsHookEx(hookId);
                    hookId = IntPtr.Zero;
                }
            }
            catch (Exception ex)
            {
                if (debugLog != null) debugLog("Mouse hook cleanup exception: " + ex.Message);
            }
        }

        private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            try
            {
                if (nCode >= 0)
                {
                    int message = wParam.ToInt32();
                    if (message == WM_XBUTTONDOWN || message == WM_XBUTTONUP)
                    {
                        MSLLHOOKSTRUCT data = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
                        int button = (int)((data.mouseData >> 16) & 0xFFFF);

                        if (button == XBUTTON1)
                        {
                            if (message == WM_XBUTTONDOWN)
                            {
                                if (debugLog != null) debugLog("XButton1 DOWN intercepted.");
                                if (onActionTriggered != null) onActionTriggered("COLLECT");
                            }
                            return (IntPtr)1;
                        }
                        if (button == XBUTTON2)
                        {
                            if (message == WM_XBUTTONDOWN)
                            {
                                if (debugLog != null) debugLog("XButton2 DOWN intercepted.");
                                if (onActionTriggered != null) onActionTriggered("PASTE");
                            }
                            return (IntPtr)1;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                if (debugLog != null) debugLog("Mouse hook exception: " + ex.Message);
            }
            return CallNextHookEx(hookId, nCode, wParam, lParam);
        }
    }

    // ==========================================
    // 5. Queue Layer
    // ==========================================
    public class ClipboardQueue
    {
        private readonly Queue<string> queue = new Queue<string>();
        private readonly object lockObj = new object();

        public void Enqueue(string text)
        {
            lock (lockObj) { queue.Enqueue(text); }
        }

        public string Dequeue()
        {
            lock (lockObj)
            {
                return queue.Count > 0 ? queue.Dequeue() : null;
            }
        }

        public void RestoreItem(string text)
        {
            if (text == null) return;
            lock (lockObj)
            {
                Queue<string> restored = new Queue<string>();
                restored.Enqueue(text);
                while (queue.Count > 0) restored.Enqueue(queue.Dequeue());
                while (restored.Count > 0) queue.Enqueue(restored.Dequeue());
            }
        }

        public int Clear()
        {
            lock (lockObj)
            {
                int count = queue.Count;
                queue.Clear();
                return count;
            }
        }

        public int Count
        {
            get { lock (lockObj) { return queue.Count; } }
        }

        public void ShowStatus()
        {
            lock (lockObj)
            {
                Console.WriteLine();
                Console.WriteLine("Queue size: " + queue.Count);
                int index = 1;
                foreach (string item in queue)
                {
                    string preview = item.Replace("\r", " ").Replace("\n", " ");
                    if (preview.Length > 80) preview = preview.Substring(0, 80) + "...";
                    Console.WriteLine(index + ". " + preview);
                    index++;
                }
                Console.WriteLine();
            }
        }
    }

    // ==========================================
    // 6. Application Layer
    // ==========================================
    public class PickPasteApp
    {
        private const int WM_HOTKEY = 0x0312;
        private const string MutexName = "Local\\PickPaste_SingleInstance";
        private const int UIWidth = 54;

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int x; public int y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public POINT pt;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG lpMsg);
        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG lpMsg);

        private readonly ClipboardQueue queueManager = new ClipboardQueue();
        private readonly HotkeyManager hotkeyManager = new HotkeyManager();
        private MouseHook mouseHook;

        private readonly object operationLock = new object();
        private readonly bool enableKeyboard;
        private readonly bool enableXButton;
        private readonly bool debug;

        private readonly string hkCollectStr;
        private readonly string hkPasteStr;
        private readonly string hkClearStr;
        private readonly string hkStatusStr;

        private volatile bool stopping;
        private Mutex instanceMutex;

        public PickPasteApp(bool enableKeyboard, bool enableXButton, bool debugMode,
                            string hkCollect, string hkPaste, string hkClear, string hkStatus)
        {
            this.enableKeyboard = enableKeyboard;
            this.enableXButton  = enableXButton;
            this.debug          = debugMode;
            this.hkCollectStr   = hkCollect;
            this.hkPasteStr     = hkPaste;
            this.hkClearStr     = hkClear;
            this.hkStatusStr    = hkStatus;
        }

        private void DebugLog(string message)
        {
            if (debug) Console.WriteLine(message);
        }

        private void Log(string message) { Console.WriteLine(message); }

        private void LogTimestamped(string message)
        {
            Console.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + message);
        }

        private void PrintHeader()
        {
            string title = " PickPaste ";
            int totalPad = UIWidth - title.Length;
            int padLeft = totalPad / 2;
            int padRight = totalPad - padLeft;

            string line = new string('=', UIWidth);
            string headerText = new string(' ', padLeft) + title + new string(' ', padRight);

            Console.WriteLine(line);
            Console.WriteLine(headerText);
            Console.WriteLine(line + "\n");
        }

        public void Run()
        {
            Console.Clear();
            PrintHeader();

            if (!AcquireSingleInstance())
            {
                Console.WriteLine("[ERROR] PickPaste is already running.");
                Console.WriteLine("Please close the existing instance before launching a new one.");
                return;
            }

            Console.WriteLine("Keyboard Shortcuts:");

            List<HotkeyCheckResult> conflicts = new List<HotkeyCheckResult>();

            if (enableKeyboard)
            {
                HotkeyCheckResult cCollect = HotkeyManager.InspectHotkey("Collect Text", hkCollectStr);
                HotkeyCheckResult cPaste   = HotkeyManager.InspectHotkey("Paste Item", hkPasteStr);
                HotkeyCheckResult cClear   = HotkeyManager.InspectHotkey("Clear Queue", hkClearStr);
                HotkeyCheckResult cStatus  = HotkeyManager.InspectHotkey("Show Status", hkStatusStr);

                PrintInspectionLine(cCollect.ActionName, cCollect.HotkeyStr, cCollect.Status, cCollect.ErrorMessage);
                PrintInspectionLine(cPaste.ActionName, cPaste.HotkeyStr, cPaste.Status, cPaste.ErrorMessage);
                PrintInspectionLine(cClear.ActionName, cClear.HotkeyStr, cClear.Status, cClear.ErrorMessage);
                PrintInspectionLine(cStatus.ActionName, cStatus.HotkeyStr, cStatus.Status, cStatus.ErrorMessage);

                if (cCollect.Status == InspectionStatus.Failed) conflicts.Add(cCollect);
                if (cPaste.Status == InspectionStatus.Failed)   conflicts.Add(cPaste);
                if (cClear.Status == InspectionStatus.Failed)   conflicts.Add(cClear);
                if (cStatus.Status == InspectionStatus.Failed)  conflicts.Add(cStatus);
            }
            else
            {
                PrintInspectionLine("Collect Text", "-", InspectionStatus.Disabled, string.Empty);
                PrintInspectionLine("Paste Item", "-", InspectionStatus.Disabled, string.Empty);
                PrintInspectionLine("Clear Queue", "-", InspectionStatus.Disabled, string.Empty);
                PrintInspectionLine("Show Status", "-", InspectionStatus.Disabled, string.Empty);
            }
            
            Console.WriteLine("\nMouse Navigation:");
            if (enableXButton)
            {
                PrintInspectionLine("Collect Text", "XButton1", InspectionStatus.Ok, string.Empty);
                PrintInspectionLine("Paste Item", "XButton2", InspectionStatus.Ok, string.Empty);
            }
            else
            {
                PrintInspectionLine("Collect Text", "-", InspectionStatus.Disabled, string.Empty);
                PrintInspectionLine("Paste Item", "-", InspectionStatus.Disabled, string.Empty);
            }

            Console.WriteLine();

            if (conflicts.Count > 0)
            {
                Console.WriteLine(new string('-', UIWidth));
                Console.WriteLine("[WARNING] " + conflicts.Count + " shortcut(s) failed check:");
                foreach (var c in conflicts)
                {
                    Console.WriteLine("  * " + c.ActionName + " [" + c.HotkeyStr + "]: " + c.ErrorMessage);
                    Console.WriteLine("    Suggestion: " + c.Suggestion);
                }
                if (enableXButton)
                {
                    Console.WriteLine("  * Fallback: You can still use Mouse XButton1/XButton2 for main operations.");
                }
                Console.WriteLine(new string('-', UIWidth) + "\n");
            }

            try
            {
                if (enableKeyboard)
                {
                    hotkeyManager.RegisterCustom(HotkeyManager.HOTKEY_ID_COLLECT, hkCollectStr, DebugLog);
                    hotkeyManager.RegisterCustom(HotkeyManager.HOTKEY_ID_PASTE,   hkPasteStr,   DebugLog);
                    hotkeyManager.RegisterCustom(HotkeyManager.HOTKEY_ID_CLEAR,   hkClearStr,   DebugLog);
                    hotkeyManager.RegisterCustom(HotkeyManager.HOTKEY_ID_STATUS,  hkStatusStr,  DebugLog);
                }

                if (enableXButton)
                {
                    mouseHook = new MouseHook(StartDelayedOperation, DebugLog);
                    if (!mouseHook.Install())
                    {
                        Console.WriteLine("[WARNING] Could not install low-level mouse hook.");
                    }
                }

                Console.WriteLine("PickPaste is running.\nKeep this window open to stay active, or close it to exit.\n");
                MessageLoop();
            }
            finally
            {
                Cleanup();
            }
        }

        private void PrintInspectionLine(string label, string binding, InspectionStatus status, string errorMsg)
        {
            string paddedLabel = label.PadRight(18);
            string paddedBinding = ("[" + binding + "]").PadRight(18);

            switch (status)
            {
                case InspectionStatus.Ok:
                    Console.WriteLine("  " + paddedLabel + paddedBinding + "--> [ OK ]");
                    break;
                case InspectionStatus.Disabled:
                    Console.WriteLine("  " + paddedLabel + paddedBinding + "--> [ DISABLED ]");
                    break;
                case InspectionStatus.Failed:
                    Console.WriteLine("  " + paddedLabel + paddedBinding + "--> [ FAILED ] (" + errorMsg + ")");
                    break;
            }
        }

        private bool AcquireSingleInstance()
        {
            try
            {
                bool createdNew;
                instanceMutex = new Mutex(true, MutexName, out createdNew);
                if (!createdNew)
                {
                    instanceMutex.Dispose();
                    instanceMutex = null;
                    return false;
                }
                DebugLog("Single-instance mutex acquired.");
                return true;
            }
            catch (Exception ex)
            {
                DebugLog("Single-instance mutex error: " + ex.Message);
                return true;
            }
        }

        private void MessageLoop()
        {
            MSG msg;
            while (!stopping)
            {
                int result;
                try
                {
                    result = GetMessage(out msg, IntPtr.Zero, 0, 0);
                }
                catch (Exception ex)
                {
                    DebugLog("GetMessage exception: " + ex.Message);
                    break;
                }
                if (result <= 0) break;
                try
                {
                    if (msg.message == WM_HOTKEY)
                    {
                        HandleHotkey(msg.wParam.ToInt32());
                    }
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
                catch (Exception ex)
                {
                    DebugLog("Message processing exception: " + ex.Message);
                }
            }
        }

        private void HandleHotkey(int id)
        {
            switch (id)
            {
                case HotkeyManager.HOTKEY_ID_COLLECT: StartDelayedOperation("COLLECT"); break;
                case HotkeyManager.HOTKEY_ID_PASTE:   StartDelayedOperation("PASTE"); break;
                case HotkeyManager.HOTKEY_ID_CLEAR:   StartDelayedOperation("CLEAR"); break;
                case HotkeyManager.HOTKEY_ID_STATUS:  StartDelayedOperation("STATUS"); break;
            }
        }

        private void StartDelayedOperation(string operation)
        {
            Thread thread = new Thread(() =>
            {
                try
                {
                    Thread.Sleep(200);
                    switch (operation)
                    {
                        case "COLLECT": CollectText(); break;
                        case "PASTE":   PasteNext(); break;
                        case "CLEAR":   ClearQueue(); break;
                        case "STATUS":  ShowStatus(); break;
                    }
                }
                catch (Exception ex)
                {
                    DebugLog("Operation exception (" + operation + "): " + ex.Message);
                    if (!debug) Console.WriteLine("PickPaste operation failed. Run with -debug for details.");
                }
            });
            thread.IsBackground = true;
            thread.Start();
        }

        private void CollectText()
        {
            lock (operationLock)
            {
                try
                {
                    LogTimestamped("Collect started.");
                    DebugLog("Waiting for input buttons to release...");
                    KeyboardController.WaitForModifierKeys(DebugLog);

                    string previousClipboard = ClipboardManager.GetClipboardText();
                    uint sequenceBefore = ClipboardManager.GetClipboardSequenceNumber();
                    DebugLog("Clipboard sequence before: " + sequenceBefore);
                    DebugLog("Sending Ctrl+C...");

                    if (!KeyboardController.SendCtrlC(DebugLog))
                    {
                        DebugLog("FAILED: Could not send Ctrl+C.");
                        if (!debug) Console.WriteLine("Collect failed.");
                        return;
                    }

                    string text = ClipboardManager.WaitForNewClipboardText(sequenceBefore, 2000, DebugLog);
                    if (String.IsNullOrWhiteSpace(text))
                    {
                        uint sequenceAfter = ClipboardManager.GetClipboardSequenceNumber();
                        DebugLog("Clipboard sequence after: " + sequenceAfter);
                        DebugLog("FAILED: No text was copied.");
                        DebugLog("Possible causes:");
                        DebugLog("  - No text was selected.");
                        DebugLog("  - Target application did not process Ctrl+C.");
                        DebugLog("  - Target application uses a non-standard copy mechanism.");
                        if (!debug) Console.WriteLine("Nothing was collected.");
                        return;
                    }

                    queueManager.Enqueue(text);
                    Log("Collected: " + text.Length + " characters. Queue: " + queueManager.Count);
                    DebugLog("SUCCESS: Item collected.\nCharacters: " + text.Length + "\nQueue size: " + queueManager.Count);

                    ClipboardManager.RestoreClipboard(previousClipboard, sequenceBefore, DebugLog);
                    DebugLog("");
                }
                catch (Exception ex)
                {
                    DebugLog("Collect exception: " + ex.Message);
                }
            }
        }

        private void PasteNext()
        {
            lock (operationLock)
            {
                try
                {
                    LogTimestamped("Paste started.");
                    KeyboardController.WaitForModifierKeys(DebugLog);

                    string text = queueManager.Dequeue();
                    if (text == null)
                    {
                        Log("Queue is empty.");
                        DebugLog("");
                        return;
                    }

                    if (!ClipboardManager.SetClipboardText(text))
                    {
                        DebugLog("FAILED: Could not set clipboard.");
                        queueManager.RestoreItem(text);
                        if (!debug) Console.WriteLine("Paste failed. Item returned to queue.");
                        return;
                    }

                    Thread.Sleep(100);
                    DebugLog("Sending Ctrl+V...");

                    if (!KeyboardController.SendCtrlV(DebugLog))
                    {
                        DebugLog("FAILED: Could not send Ctrl+V.");
                        queueManager.RestoreItem(text);
                        if (!debug) Console.WriteLine("Paste failed. Item returned to queue.");
                        return;
                    }

                    Log("Pasted. Remaining: " + queueManager.Count);
                    DebugLog("SUCCESS: Item pasted.\nRemaining items: " + queueManager.Count + "\n");
                }
                catch (Exception ex)
                {
                    DebugLog("Paste exception: " + ex.Message);
                }
            }
        }

        private void ClearQueue()
        {
            int count = queueManager.Clear();
            Log("Queue cleared. Removed: " + count);
            DebugLog("");
        }

        private void ShowStatus()
        {
            queueManager.ShowStatus();
        }

        private void Cleanup()
        {
            if (stopping) return;
            stopping = true;

            hotkeyManager.UnregisterAll(DebugLog);
            if (mouseHook != null)
            {
                mouseHook.Uninstall();
                mouseHook = null;
            }

            try
            {
                if (instanceMutex != null)
                {
                    instanceMutex.ReleaseMutex();
                    instanceMutex.Dispose();
                    instanceMutex = null;
                }
            }
            catch { }

            DebugLog("PickPaste cleanup completed.");
        }
    }
}
"@

try {
    $app = New-Object "${DynamicNamespace}.PickPasteApp"(
        [bool]$EnableKeyboard,
        [bool]$EnableXButton,
        [bool]$debug,
        [string]$config.HotkeyCollect,
        [string]$config.HotkeyPaste,
        [string]$config.HotkeyClear,
        [string]$config.HotkeyStatus
    )
    $app.Run()
}
catch {
    Write-Host "`n========================================"
    Write-Host "PickPaste failed to start."
    Write-Host "========================================`n"
    Write-Host $_.Exception.Message
    Write-Host ""
    if ($debug) {
        Write-Host $_.Exception.ToString()
        Write-Host ""
    }
    Write-Host "Press Enter to close."
    Read-Host
}