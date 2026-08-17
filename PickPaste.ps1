param(
    [switch]$debug
)

$ErrorActionPreference = "Stop"

# ============================================================
# PickPaste
# ============================================================

$ProductName = "PickPaste"

# INI is located beside the PS1/EXE.
# Handle ps2exe conversion: determine the correct directory
function Get-ExecutionRoot {
    # Try $PSScriptRoot first
    if (-not [string]::IsNullOrEmpty($PSScriptRoot) -and $PSScriptRoot -ne ".") {
        return $PSScriptRoot
    }
    
    # Try $MyInvocation
    if (-not [string]::IsNullOrEmpty($MyInvocation.MyCommand.Path)) {
        return Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    
    # Try $PSCommandPath
    if (-not [string]::IsNullOrEmpty($PSCommandPath)) {
        return Split-Path -Parent $PSCommandPath
    }
    
    # Try to get from current process (works best for ps2exe)
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -and $exePath.EndsWith(".exe")) {
            return Split-Path -Parent $exePath
        }
    } catch { }
    
    # Fallback to current directory
    return (Get-Location).Path
}

$ScriptRoot = Get-ExecutionRoot

$ConfigPath = Join-Path $ScriptRoot "config.ini"

# ------------------------------------------------------------
# Default configuration
# ------------------------------------------------------------

$EnableKeyboard = $true
$EnableXButton  = $false

# ------------------------------------------------------------
# INI parser
#
# Supported:
#
# [Hotkeys]
# EnableKeyboard=true
# EnableXButton=false
#
# Section names are optional.
# ------------------------------------------------------------

function ConvertTo-BoolValue {
    param(
        [string]$Value,
        [bool]$DefaultValue
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $DefaultValue
    }

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
    param(
        [string]$Path
    )

    $config = @{
        EnableKeyboard = $true
        EnableXButton  = $true
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $config
    }

    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop

        foreach ($line in $lines) {

            $trimmed = $line.Trim()

            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            if ($trimmed.StartsWith("#")) {
                continue
            }

            if ($trimmed.StartsWith(";")) {
                continue
            }

            if ($trimmed.StartsWith("[")) {
                continue
            }

            $parts = $trimmed.Split(
                "=",
                2,
                [System.StringSplitOptions]::None
            )

            if ($parts.Count -ne 2) {
                continue
            }

            $key = $parts[0].Trim()
            $value = $parts[1].Trim()

            switch ($key.ToLowerInvariant()) {

                "enablekeyboard" {
                    $config.EnableKeyboard =
                        ConvertTo-BoolValue `
                            $value `
                            $config.EnableKeyboard
                }

                "enablexbutton" {
                    $config.EnableXButton =
                        ConvertTo-BoolValue `
                            $value `
                            $config.EnableXButton
                }
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host "WARNING: Could not read configuration file."
        Write-Host "Using default configuration."
        Write-Host "Error: $($_.Exception.Message)"
        Write-Host ""
    }

    return $config
}

# ------------------------------------------------------------
# Read configuration BEFORE compiling C#
# ------------------------------------------------------------

$config = Read-PickPasteConfig -Path $ConfigPath

$EnableKeyboard = [bool]$config.EnableKeyboard
$EnableXButton  = [bool]$config.EnableXButton

# ------------------------------------------------------------
# C# implementation
# ------------------------------------------------------------

Add-Type @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class PickPasteApp
{
    // ========================================================
    // Windows messages
    // ========================================================

    private const int WM_HOTKEY       = 0x0312;

    private const int WM_XBUTTONDOWN  = 0x020B;
    private const int WM_XBUTTONUP    = 0x020C;

    private const int WH_MOUSE_LL     = 14;

    // ========================================================
    // X buttons
    // ========================================================

    private const int XBUTTON1 = 0x0001;
    private const int XBUTTON2 = 0x0002;

    // Virtual keys for physical mouse buttons
    private const int VK_XBUTTON1 = 0x05;
    private const int VK_XBUTTON2 = 0x06;

    // ========================================================
    // Hotkey IDs
    // ========================================================

    private const int HOTKEY_ID_COLLECT = 1001;
    private const int HOTKEY_ID_PASTE   = 1002;
    private const int HOTKEY_ID_CLEAR   = 1003;
    private const int HOTKEY_ID_STATUS  = 1004;

    // ========================================================
    // Hotkey modifiers
    // ========================================================

    private const uint MOD_ALT      = 0x0001;
    private const uint MOD_CONTROL  = 0x0002;
    private const uint MOD_NOREPEAT = 0x4000;

    // ========================================================
    // Virtual keys
    // ========================================================

    private const uint VK_CONTROL = 0x11;
    private const uint VK_MENU    = 0x12;

    private const uint VK_C = 0x43;
    private const uint VK_V = 0x56;
    private const uint VK_Q = 0x51;
    private const uint VK_X = 0x58;

    private const uint KEYEVENTF_KEYUP = 0x0002;

    // ========================================================
    // Clipboard
    // ========================================================

    private const uint CF_UNICODETEXT = 13;
    private const uint GMEM_MOVEABLE  = 0x0002;

    // ========================================================
    // State
    // ========================================================

    private readonly Queue<string> queue =
        new Queue<string>();

    private readonly object queueLock =
        new object();

    private readonly object operationLock =
        new object();

    private readonly bool enableKeyboard;
    private readonly bool enableXButton;
    private readonly bool debug;

    private IntPtr mouseHook = IntPtr.Zero;

    private LowLevelMouseProc mouseProc;

    private bool collectHotkeyRegistered;
    private bool pasteHotkeyRegistered;
    private bool clearHotkeyRegistered;
    private bool statusHotkeyRegistered;

    private volatile bool stopping;

    // Prevent multiple PickPaste instances in the same
    // interactive Windows session.
    private Mutex instanceMutex;

    private const string MutexName =
        "Local\\PickPaste_SingleInstance";

    // ========================================================
    // Constructor
    // ========================================================

    public PickPasteApp(
        bool enableKeyboard,
        bool enableXButton,
        bool debugMode)
    {
        this.enableKeyboard = enableKeyboard;
        this.enableXButton = enableXButton;
        this.debug = debugMode;
    }

    // ========================================================
    // Logging
    // ========================================================

    private void DebugLog(string message)
    {
        if (!debug)
            return;

        Console.WriteLine(message);
    }

    private void Log(string message)
    {
        Console.WriteLine(message);
    }

    private void LogTimestamped(string message)
    {
        Console.WriteLine(
            "[" +
            DateTime.Now.ToString("HH:mm:ss") +
            "] " +
            message
        );
    }

    // ========================================================
    // Run
    // ========================================================

    public void Run()
    {
        Console.Clear();

        Console.WriteLine("========================================");
        Console.WriteLine("               PickPaste");
        Console.WriteLine("========================================");

        Console.WriteLine();

        Console.WriteLine("Configuration:");
        Console.WriteLine(
            "  Keyboard shortcuts: " +
            (enableKeyboard ? "ENABLED" : "DISABLED")
        );

        Console.WriteLine(
            "  XButton shortcuts:  " +
            (enableXButton ? "ENABLED" : "DISABLED")
        );

        Console.WriteLine(
            "  Debug logging:      " +
            (debug ? "ENABLED" : "DISABLED")
        );

        Console.WriteLine();

        Console.WriteLine("Keyboard:");

        if (enableKeyboard)
        {
            Console.WriteLine(
                "  Ctrl + Alt + C  Collect selected text"
            );

            Console.WriteLine(
                "  Ctrl + Alt + V  Paste next item"
            );

            Console.WriteLine(
                "  Ctrl + Alt + X  Clear queue"
            );

            Console.WriteLine(
                "  Ctrl + Alt + Q  Show queue"
            );
        }
        else
        {
            Console.WriteLine("  DISABLED");
        }

        Console.WriteLine();

        Console.WriteLine("Mouse:");

        if (enableXButton)
        {
            Console.WriteLine(
                "  XButton1        Collect selected text"
            );

            Console.WriteLine(
                "  XButton2        Paste next item"
            );
        }
        else
        {
            Console.WriteLine("  DISABLED");
        }

        Console.WriteLine();

        Console.WriteLine("Exit:");
        Console.WriteLine(
            "  Close this window to exit PickPaste."
        );

        Console.WriteLine();

        // ----------------------------------------------------
        // Single instance
        // ----------------------------------------------------

        if (!AcquireSingleInstance())
        {
            Console.WriteLine(
                "ERROR: PickPaste is already running."
            );

            Console.WriteLine(
                "Close the existing PickPaste window first."
            );

            return;
        }

        try
        {
            // ------------------------------------------------
            // Register keyboard hotkeys
            // ------------------------------------------------

            if (enableKeyboard)
            {
                RegisterHotkeys();
            }
            else
            {
                DebugLog(
                    "Keyboard hotkeys are disabled by configuration."
                );
            }

            // ------------------------------------------------
            // Install mouse hook
            // ------------------------------------------------

            if (enableXButton)
            {
                InstallMouseHook();
            }
            else
            {
                DebugLog(
                    "XButton mouse hook is disabled by configuration."
                );
            }

            Console.WriteLine(
                "PickPaste is running."
            );

            Console.WriteLine();

            // ------------------------------------------------
            // Message loop
            // ------------------------------------------------

            MessageLoop();
        }
        finally
        {
            Cleanup();
        }
    }

    // ========================================================
    // Single instance
    // ========================================================

    private bool AcquireSingleInstance()
    {
        try
        {
            bool createdNew;

            instanceMutex = new Mutex(
                true,
                MutexName,
                out createdNew
            );

            if (!createdNew)
            {
                instanceMutex.Dispose();
                instanceMutex = null;

                return false;
            }

            DebugLog(
                "Single-instance mutex acquired."
            );

            return true;
        }
        catch (Exception ex)
        {
            DebugLog(
                "Single-instance mutex error: " +
                ex.Message
            );

            // If mutex cannot be created, do not crash.
            // Allow the application to continue.
            return true;
        }
    }

    // ========================================================
    // Hotkeys
    // ========================================================

    private void RegisterHotkeys()
    {
        collectHotkeyRegistered =
            RegisterHotKey(
                IntPtr.Zero,
                HOTKEY_ID_COLLECT,
                MOD_CONTROL |
                MOD_ALT |
                MOD_NOREPEAT,
                VK_C
            );

        pasteHotkeyRegistered =
            RegisterHotKey(
                IntPtr.Zero,
                HOTKEY_ID_PASTE,
                MOD_CONTROL |
                MOD_ALT |
                MOD_NOREPEAT,
                VK_V
            );

        clearHotkeyRegistered =
            RegisterHotKey(
                IntPtr.Zero,
                HOTKEY_ID_CLEAR,
                MOD_CONTROL |
                MOD_ALT |
                MOD_NOREPEAT,
                VK_X
            );

        statusHotkeyRegistered =
            RegisterHotKey(
                IntPtr.Zero,
                HOTKEY_ID_STATUS,
                MOD_CONTROL |
                MOD_ALT |
                MOD_NOREPEAT,
                VK_Q
            );

        DebugLog(
            "Ctrl+Alt+C registration: " +
            collectHotkeyRegistered
        );

        DebugLog(
            "Ctrl+Alt+V registration: " +
            pasteHotkeyRegistered
        );

        DebugLog(
            "Ctrl+Alt+X registration: " +
            clearHotkeyRegistered
        );

        DebugLog(
            "Ctrl+Alt+Q registration: " +
            statusHotkeyRegistered
        );

        if (!collectHotkeyRegistered ||
            !pasteHotkeyRegistered ||
            !clearHotkeyRegistered ||
            !statusHotkeyRegistered)
        {
            int error = Marshal.GetLastWin32Error();

            DebugLog(
                "RegisterHotKey Windows error code: " +
                error
            );

            if (!debug)
            {
                Console.WriteLine(
                    "WARNING: One or more keyboard shortcuts could not be registered."
                );

                Console.WriteLine(
                    "Run with -debug for details."
                );

                Console.WriteLine();
            }
        }
    }

    // ========================================================
    // Mouse hook
    // ========================================================

    private void InstallMouseHook()
    {
        try
        {
            mouseProc = MouseHookCallback;

            mouseHook = SetWindowsHookEx(
                WH_MOUSE_LL,
                mouseProc,
                GetModuleHandle(null),
                0
            );

            if (mouseHook == IntPtr.Zero)
            {
                int error =
                    Marshal.GetLastWin32Error();

                DebugLog(
                    "ERROR: Mouse hook installation failed."
                );

                DebugLog(
                    "Windows error code: " +
                    error
                );

                if (!debug)
                {
                    Console.WriteLine(
                        "WARNING: XButton shortcuts could not be enabled."
                    );

                    Console.WriteLine(
                        "Run with -debug for details."
                    );

                    Console.WriteLine();
                }

                return;
            }

            DebugLog(
                "Low-level mouse hook installed."
            );
        }
        catch (Exception ex)
        {
            DebugLog(
                "Mouse hook exception: " +
                ex.Message
            );
        }
    }

    // ========================================================
    // Message loop
    // ========================================================

    private void MessageLoop()
    {
        MSG msg;

        while (!stopping)
        {
            int result;

            try
            {
                result = GetMessage(
                    out msg,
                    IntPtr.Zero,
                    0,
                    0
                );
            }
            catch (Exception ex)
            {
                DebugLog(
                    "GetMessage exception: " +
                    ex.Message
                );

                break;
            }

            if (result <= 0)
            {
                break;
            }

            try
            {
                if (msg.message == WM_HOTKEY)
                {
                    HandleHotkey(
                        msg.wParam.ToInt32()
                    );
                }

                TranslateMessage(ref msg);

                DispatchMessage(ref msg);
            }
            catch (Exception ex)
            {
                DebugLog(
                    "Message processing exception: " +
                    ex.Message
                );
            }
        }
    }

    // ========================================================
    // Hotkey dispatch
    // ========================================================

    private void HandleHotkey(int id)
    {
        switch (id)
        {
            case HOTKEY_ID_COLLECT:

                StartDelayedOperation(
                    "COLLECT"
                );

                break;

            case HOTKEY_ID_PASTE:

                StartDelayedOperation(
                    "PASTE"
                );

                break;

            case HOTKEY_ID_CLEAR:

                StartDelayedOperation(
                    "CLEAR"
                );

                break;

            case HOTKEY_ID_STATUS:

                StartDelayedOperation(
                    "STATUS"
                );

                break;
        }
    }

    // ========================================================
    // Start operation
    // ========================================================

    private void StartDelayedOperation(
        string operation)
    {
        Thread thread =
            new Thread(
                () =>
                {
                    try
                    {
                        // Give the original hotkey/mouse event
                        // time to finish before injecting Ctrl+C/V.
                        Thread.Sleep(200);

                        switch (operation)
                        {
                            case "COLLECT":
                                CollectText();
                                break;

                            case "PASTE":
                                PasteNext();
                                break;

                            case "CLEAR":
                                ClearQueue();
                                break;

                            case "STATUS":
                                ShowStatus();
                                break;
                        }
                    }
                    catch (Exception ex)
                    {
                        DebugLog(
                            "Operation exception (" +
                            operation +
                            "): " +
                            ex.Message
                        );

                        if (!debug)
                        {
                            Console.WriteLine(
                                "PickPaste operation failed. Run with -debug for details."
                            );
                        }
                    }
                }
            );

        thread.IsBackground = true;
        thread.Start();
    }

    // ========================================================
    // Mouse callback
    //
    // IMPORTANT:
    // Both DOWN and UP are intercepted.
    //
    // This prevents browsers and other applications from
    // receiving XButton navigation events.
    // ========================================================

    private IntPtr MouseHookCallback(
        int nCode,
        IntPtr wParam,
        IntPtr lParam)
    {
        try
        {
            if (nCode >= 0)
            {
                int message =
                    wParam.ToInt32();

                if (message == WM_XBUTTONDOWN ||
                    message == WM_XBUTTONUP)
                {
                    MSLLHOOKSTRUCT data =
                        Marshal.PtrToStructure<MSLLHOOKSTRUCT>(
                            lParam
                        );

                    int button =
                        (int)(
                            (data.mouseData >> 16) &
                            0xFFFF
                        );

                    if (button == XBUTTON1)
                    {
                        if (message == WM_XBUTTONDOWN)
                        {
                            DebugLog(
                                "XButton1 DOWN intercepted."
                            );

                            StartDelayedOperation(
                                "COLLECT"
                            );
                        }
                        else
                        {
                            DebugLog(
                                "XButton1 UP intercepted."
                            );
                        }

                        // Swallow both DOWN and UP.
                        return (IntPtr)1;
                    }

                    if (button == XBUTTON2)
                    {
                        if (message == WM_XBUTTONDOWN)
                        {
                            DebugLog(
                                "XButton2 DOWN intercepted."
                            );

                            StartDelayedOperation(
                                "PASTE"
                            );
                        }
                        else
                        {
                            DebugLog(
                                "XButton2 UP intercepted."
                            );
                        }

                        // Swallow both DOWN and UP.
                        return (IntPtr)1;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            DebugLog(
                "Mouse hook exception: " +
                ex.Message
            );

            // Never allow a hook exception to propagate.
        }

        return CallNextHookEx(
            mouseHook,
            nCode,
            wParam,
            lParam
        );
    }

    // ========================================================
    // COLLECT
    // ========================================================

    private void CollectText()
    {
        lock (operationLock)
        {
            try
            {
                LogTimestamped(
                    "Collect started."
                );

                DebugLog(
                    "Waiting for input buttons to release..."
                );

                WaitForModifierKeys();

                string previousClipboard =
                    GetClipboardText();

                uint sequenceBefore =
                    GetClipboardSequenceNumber();

                DebugLog(
                    "Clipboard sequence before: " +
                    sequenceBefore
                );

                DebugLog(
                    "Sending Ctrl+C..."
                );

                if (!SendCtrlC())
                {
                    DebugLog(
                        "FAILED: Could not send Ctrl+C."
                    );

                    if (!debug)
                    {
                        Console.WriteLine(
                            "Collect failed."
                        );
                    }

                    return;
                }

                string text =
                    WaitForNewClipboardText(
                        sequenceBefore,
                        2000
                    );

                if (String.IsNullOrWhiteSpace(text))
                {
                    uint sequenceAfter =
                        GetClipboardSequenceNumber();

                    DebugLog(
                        "Clipboard sequence after: " +
                        sequenceAfter
                    );

                    DebugLog(
                        "FAILED: No text was copied."
                    );

                    DebugLog(
                        "Possible causes:"
                    );

                    DebugLog(
                        "  - No text was selected."
                    );

                    DebugLog(
                        "  - Target application did not process Ctrl+C."
                    );

                    DebugLog(
                        "  - Target application uses a non-standard copy mechanism."
                    );

                    if (!debug)
                    {
                        Console.WriteLine(
                            "Nothing was collected."
                        );
                    }

                    return;
                }

                lock (queueLock)
                {
                    queue.Enqueue(text);
                }

                Log(
                    "Collected: " +
                    text.Length +
                    " characters. " +
                    "Queue: " +
                    GetQueueCount()
                );

                DebugLog(
                    "SUCCESS: Item collected."
                );

                DebugLog(
                    "Characters: " +
                    text.Length
                );

                DebugLog(
                    "Queue size: " +
                    GetQueueCount()
                );

                // ------------------------------------------------
                // Restore user's previous clipboard.
                //
                // Only restore if nobody changed the clipboard
                // after our Ctrl+C.
                // ------------------------------------------------

                if (previousClipboard != null)
                {
                    Thread.Sleep(50);

                    uint currentSequence =
                        GetClipboardSequenceNumber();

                    if (currentSequence != sequenceBefore)
                    {
                        // We expect exactly the sequence produced
                        // by our copy. Restore only if it still
                        // hasn't changed since then.
                        string currentText =
                            GetClipboardText();

                        uint afterReadSequence =
                            GetClipboardSequenceNumber();

                        if (afterReadSequence ==
                            currentSequence)
                        {
                            if (!SetClipboardText(
                                previousClipboard))
                            {
                                DebugLog(
                                    "WARNING: Could not restore previous clipboard."
                                );
                            }
                            else
                            {
                                DebugLog(
                                    "Previous clipboard restored."
                                );
                            }
                        }
                        else
                        {
                            DebugLog(
                                "Clipboard changed during restore window; "
                                + "previous clipboard was not restored."
                            );
                        }
                    }
                }

                DebugLog("");
            }
            catch (Exception ex)
            {
                DebugLog(
                    "Collect exception: " +
                    ex.Message
                );
            }
        }
    }

    // ========================================================
    // PASTE
    // ========================================================

    private void PasteNext()
    {
        lock (operationLock)
        {
            try
            {
                LogTimestamped(
                    "Paste started."
                );

                WaitForModifierKeys();

                string text = null;

                lock (queueLock)
                {
                    if (queue.Count > 0)
                    {
                        text = queue.Dequeue();
                    }
                }

                if (text == null)
                {
                    Log(
                        "Queue is empty."
                    );

                    DebugLog("");

                    return;
                }

                if (!SetClipboardText(text))
                {
                    DebugLog(
                        "FAILED: Could not set clipboard."
                    );

                    RestoreItem(text);

                    if (!debug)
                    {
                        Console.WriteLine(
                            "Paste failed. Item returned to queue."
                        );
                    }

                    return;
                }

                Thread.Sleep(100);

                DebugLog(
                    "Sending Ctrl+V..."
                );

                if (!SendCtrlV())
                {
                    DebugLog(
                        "FAILED: Could not send Ctrl+V."
                    );

                    RestoreItem(text);

                    if (!debug)
                    {
                        Console.WriteLine(
                            "Paste failed. Item returned to queue."
                        );
                    }

                    return;
                }

                Log(
                    "Pasted. Remaining: " +
                    GetQueueCount()
                );

                DebugLog(
                    "SUCCESS: Item pasted."
                );

                DebugLog(
                    "Remaining items: " +
                    GetQueueCount()
                );

                DebugLog("");
            }
            catch (Exception ex)
            {
                DebugLog(
                    "Paste exception: " +
                    ex.Message
                );
            }
        }
    }

    // ========================================================
    // Restore failed paste item
    // ========================================================

    private void RestoreItem(
        string text)
    {
        if (text == null)
            return;

        lock (queueLock)
        {
            Queue<string> restored =
                new Queue<string>();

            restored.Enqueue(text);

            while (queue.Count > 0)
            {
                restored.Enqueue(
                    queue.Dequeue()
                );
            }

            while (restored.Count > 0)
            {
                queue.Enqueue(
                    restored.Dequeue()
                );
            }
        }

        DebugLog(
            "Item restored to the front of queue."
        );
    }

    // ========================================================
    // CLEAR
    // ========================================================

    private void ClearQueue()
    {
        lock (queueLock)
        {
            int count =
                queue.Count;

            queue.Clear();

            Log(
                "Queue cleared. Removed: " +
                count
            );

            DebugLog("");
        }
    }

    // ========================================================
    // STATUS
    // ========================================================

    private void ShowStatus()
    {
        lock (queueLock)
        {
            Console.WriteLine();

            Console.WriteLine(
                "Queue size: " +
                queue.Count
            );

            int index = 1;

            foreach (string item in queue)
            {
                string preview =
                    item
                        .Replace("\r", " ")
                        .Replace("\n", " ");

                if (preview.Length > 80)
                {
                    preview =
                        preview.Substring(0, 80) +
                        "...";
                }

                Console.WriteLine(
                    index +
                    ". " +
                    preview
                );

                index++;
            }

            Console.WriteLine();
        }
    }

    // ========================================================
    // Wait for Ctrl / Alt / XButtons to release
    // ========================================================

    private void WaitForModifierKeys()
    {
        Stopwatch stopwatch =
            Stopwatch.StartNew();

        while (
            stopwatch.ElapsedMilliseconds < 1000
        )
        {
            bool ctrlDown =
                (GetAsyncKeyState(
                    (int)VK_CONTROL
                ) & 0x8000) != 0;

            bool altDown =
                (GetAsyncKeyState(
                    (int)VK_MENU
                ) & 0x8000) != 0;

            bool x1Down =
                (GetAsyncKeyState(
                    VK_XBUTTON1
                ) & 0x8000) != 0;

            bool x2Down =
                (GetAsyncKeyState(
                    VK_XBUTTON2
                ) & 0x8000) != 0;

            if (!ctrlDown &&
                !altDown &&
                !x1Down &&
                !x2Down)
            {
                return;
            }

            Thread.Sleep(10);
        }

        DebugLog(
            "Input buttons remained pressed after 1 second."
        );
    }

    // ========================================================
    // Send Ctrl+C
    //
    // keybd_event is intentionally used instead of the
    // previous problematic SendInput implementation.
    // ========================================================

    private bool SendCtrlC()
    {
        try
        {
            keybd_event(
                (byte)VK_CONTROL,
                0,
                0,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_C,
                0,
                0,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_C,
                0,
                KEYEVENTF_KEYUP,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_CONTROL,
                0,
                KEYEVENTF_KEYUP,
                UIntPtr.Zero
            );

            return true;
        }
        catch (Exception ex)
        {
            DebugLog(
                "SendCtrlC exception: " +
                ex.Message
            );

            // Best effort release.
            try
            {
                keybd_event(
                    (byte)VK_C,
                    0,
                    KEYEVENTF_KEYUP,
                    UIntPtr.Zero
                );

                keybd_event(
                    (byte)VK_CONTROL,
                    0,
                    KEYEVENTF_KEYUP,
                    UIntPtr.Zero
                );
            }
            catch
            {
            }

            return false;
        }
    }

    // ========================================================
    // Send Ctrl+V
    // ========================================================

    private bool SendCtrlV()
    {
        try
        {
            keybd_event(
                (byte)VK_CONTROL,
                0,
                0,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_V,
                0,
                0,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_V,
                0,
                KEYEVENTF_KEYUP,
                UIntPtr.Zero
            );

            Thread.Sleep(20);

            keybd_event(
                (byte)VK_CONTROL,
                0,
                KEYEVENTF_KEYUP,
                UIntPtr.Zero
            );

            return true;
        }
        catch (Exception ex)
        {
            DebugLog(
                "SendCtrlV exception: " +
                ex.Message
            );

            try
            {
                keybd_event(
                    (byte)VK_V,
                    0,
                    KEYEVENTF_KEYUP,
                    UIntPtr.Zero
                );

                keybd_event(
                    (byte)VK_CONTROL,
                    0,
                    KEYEVENTF_KEYUP,
                    UIntPtr.Zero
                );
            }
            catch
            {
            }

            return false;
        }
    }

    // ========================================================
    // Wait for clipboard sequence change
    // ========================================================

    private string WaitForNewClipboardText(
        uint previousSequence,
        int timeoutMilliseconds)
    {
        Stopwatch stopwatch =
            Stopwatch.StartNew();

        uint lastReportedSequence =
            previousSequence;

        while (
            stopwatch.ElapsedMilliseconds <
            timeoutMilliseconds
        )
        {
            uint currentSequence =
                GetClipboardSequenceNumber();

            if (currentSequence !=
                previousSequence)
            {
                if (currentSequence !=
                    lastReportedSequence)
                {
                    DebugLog(
                        "Clipboard sequence changed: " +
                        previousSequence +
                        " -> " +
                        currentSequence
                    );

                    lastReportedSequence =
                        currentSequence;
                }

                string text =
                    GetClipboardText();

                if (!String.IsNullOrEmpty(text))
                {
                    return text;
                }
            }

            Thread.Sleep(25);
        }

        return null;
    }

    // ========================================================
    // Get clipboard text
    // ========================================================

    private string GetClipboardText()
    {
        for (
            int attempt = 0;
            attempt < 10;
            attempt++
        )
        {
            if (!OpenClipboard(IntPtr.Zero))
            {
                Thread.Sleep(20);
                continue;
            }

            try
            {
                if (!IsClipboardFormatAvailable(
                    CF_UNICODETEXT))
                {
                    return null;
                }

                IntPtr handle =
                    GetClipboardData(
                        CF_UNICODETEXT
                    );

                if (handle == IntPtr.Zero)
                {
                    return null;
                }

                IntPtr pointer =
                    GlobalLock(handle);

                if (pointer == IntPtr.Zero)
                {
                    return null;
                }

                try
                {
                    return Marshal.PtrToStringUni(
                        pointer
                    );
                }
                finally
                {
                    GlobalUnlock(handle);
                }
            }
            catch (Exception ex)
            {
                DebugLog(
                    "GetClipboardText exception: " +
                    ex.Message
                );
            }
            finally
            {
                CloseClipboard();
            }

            Thread.Sleep(20);
        }

        return null;
    }

    // ========================================================
    // Set clipboard text
    // ========================================================

    private bool SetClipboardText(
        string text)
    {
        if (text == null)
            return false;

        for (
            int attempt = 0;
            attempt < 15;
            attempt++
        )
        {
            if (!OpenClipboard(
                IntPtr.Zero))
            {
                Thread.Sleep(40);
                continue;
            }

            IntPtr memory = IntPtr.Zero;

            try
            {
                if (!EmptyClipboard())
                {
                    DebugLog(
                        "EmptyClipboard failed."
                    );

                    continue;
                }

                byte[] bytes =
                    Encoding.Unicode.GetBytes(
                        text + "\0"
                    );

                memory =
                    GlobalAlloc(
                        GMEM_MOVEABLE,
                        (UIntPtr)bytes.Length
                    );

                if (memory == IntPtr.Zero)
                {
                    return false;
                }

                IntPtr pointer =
                    GlobalLock(memory);

                if (pointer == IntPtr.Zero)
                {
                    GlobalFree(memory);
                    memory = IntPtr.Zero;

                    return false;
                }

                try
                {
                    Marshal.Copy(
                        bytes,
                        0,
                        pointer,
                        bytes.Length
                    );
                }
                finally
                {
                    GlobalUnlock(memory);
                }

                IntPtr result =
                    SetClipboardData(
                        CF_UNICODETEXT,
                        memory
                    );

                if (result == IntPtr.Zero)
                {
                    GlobalFree(memory);
                    memory = IntPtr.Zero;

                    return false;
                }

                // Clipboard owns memory after successful
                // SetClipboardData.
                memory = IntPtr.Zero;

                return true;
            }
            catch (Exception ex)
            {
                DebugLog(
                    "SetClipboardText exception: " +
                    ex.Message
                );

                if (memory != IntPtr.Zero)
                {
                    try
                    {
                        GlobalFree(memory);
                    }
                    catch
                    {
                    }
                }
            }
            finally
            {
                CloseClipboard();
            }

            Thread.Sleep(40);
        }

        return false;
    }

    // ========================================================
    // Queue count
    // ========================================================

    private int GetQueueCount()
    {
        lock (queueLock)
        {
            return queue.Count;
        }
    }

    // ========================================================
    // Cleanup
    // ========================================================

    private void Cleanup()
    {
        if (stopping)
            return;

        stopping = true;

        try
        {
            if (collectHotkeyRegistered)
            {
                UnregisterHotKey(
                    IntPtr.Zero,
                    HOTKEY_ID_COLLECT
                );

                collectHotkeyRegistered = false;
            }

            if (pasteHotkeyRegistered)
            {
                UnregisterHotKey(
                    IntPtr.Zero,
                    HOTKEY_ID_PASTE
                );

                pasteHotkeyRegistered = false;
            }

            if (clearHotkeyRegistered)
            {
                UnregisterHotKey(
                    IntPtr.Zero,
                    HOTKEY_ID_CLEAR
                );

                clearHotkeyRegistered = false;
            }

            if (statusHotkeyRegistered)
            {
                UnregisterHotKey(
                    IntPtr.Zero,
                    HOTKEY_ID_STATUS
                );

                statusHotkeyRegistered = false;
            }
        }
        catch (Exception ex)
        {
            DebugLog(
                "Hotkey cleanup exception: " +
                ex.Message
            );
        }

        try
        {
            if (mouseHook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(
                    mouseHook
                );

                mouseHook = IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            DebugLog(
                "Mouse hook cleanup exception: " +
                ex.Message
            );
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
        catch
        {
        }

        DebugLog(
            "PickPaste cleanup completed."
        );
    }

    // ========================================================
    // Native structures
    // ========================================================

    [StructLayout(
        LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(
        LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(
        LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    private delegate IntPtr LowLevelMouseProc(
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    );

    // ========================================================
    // Win32
    // ========================================================

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern bool RegisterHotKey(
        IntPtr hWnd,
        int id,
        uint fsModifiers,
        uint vk
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern bool UnregisterHotKey(
        IntPtr hWnd,
        int id
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern int GetMessage(
        out MSG lpMsg,
        IntPtr hWnd,
        uint wMsgFilterMin,
        uint wMsgFilterMax
    );

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(
        ref MSG lpMsg
    );

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(
        ref MSG lpMsg
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelMouseProc lpfn,
        IntPtr hMod,
        uint dwThreadId
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(
        IntPtr hhk
    );

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(
        IntPtr hhk,
        int nCode,
        IntPtr wParam,
        IntPtr lParam
    );

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(
        string lpModuleName
    );

    [DllImport("user32.dll")]
    private static extern void keybd_event(
        byte bVk,
        byte bScan,
        uint dwFlags,
        UIntPtr dwExtraInfo
    );

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(
        int vKey
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern bool OpenClipboard(
        IntPtr hWndNewOwner
    );

    [DllImport("user32.dll")]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll")]
    private static extern bool IsClipboardFormatAvailable(
        uint format
    );

    [DllImport("user32.dll")]
    private static extern IntPtr GetClipboardData(
        uint uFormat
    );

    [DllImport(
        "user32.dll",
        SetLastError = true)]
    private static extern IntPtr SetClipboardData(
        uint uFormat,
        IntPtr hMem
    );

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalLock(
        IntPtr hMem
    );

    [DllImport("kernel32.dll")]
    private static extern bool GlobalUnlock(
        IntPtr hMem
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalAlloc(
        uint uFlags,
        UIntPtr dwBytes
    );

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(
        IntPtr hMem
    );
}

"@

# ============================================================
# Create and run
# ============================================================

try {
    $app = New-Object PickPasteApp(
        [bool]$EnableKeyboard,
        [bool]$EnableXButton,
        [bool]$debug
    )

    $app.Run()
}
catch {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "PickPaste failed to start."
    Write-Host "========================================"
    Write-Host ""
    Write-Host $_.Exception.Message
    Write-Host ""

    if ($debug) {
        Write-Host $_.Exception.ToString()
        Write-Host ""
    }

    Write-Host "Press Enter to close."
    Read-Host
}