<p align="center">
  <img src="assets/logo.png" width="150">
</p>
<h1 align="center">PickPaste</h1>

<p align="center">
  Copy continuously. Paste continuously.
</p>

 **English**  [📖 README.en.md](README.en.md) 
 **中文**  [📖 README.zh.md](README.zh.md) 
 **日本語**  [📖 README.ja.md](README.ja.md) 
 **Français** [📖 README.fr.md](README.fr.md) 


![PickPaste Demo](assets/pickpaste.gif)

<video src="assets/demo.mp4#t=0.002" poster="assets/demo.mp4" controls muted width="100%">
</video>

- [💭 Our Philosophy](#-our-philosophy)
- [⚡ Problem → Solution → Results](#-problem--solution--results)
  - [The Problem](#the-problem)
  - [Our Solution](#our-solution)
  - [Results](#results)
- [💡 What This Gets You](#-what-this-gets-you)
  - [💪 Efficiency Boost 200%+](#-efficiency-boost-200)
  - [🧠 Cognitive Load Drops Dramatically](#-cognitive-load-drops-dramatically)
  - [💨 Zero Learning Cost](#-zero-learning-cost)
  - [⚡ Truly Lightweight](#-truly-lightweight)
  - [🎯 Minimalist Philosophy](#-minimalist-philosophy)
- [👥 Who Loves This \& How It Helps](#-who-loves-this--how-it-helps)
  - [Sales/Operations — Extract info from multiple sources](#salesoperations--extract-info-from-multiple-sources)
  - [Editors/Journalists — Organize multi-source research](#editorsjournalists--organize-multi-source-research)
  - [Developers — Collect error messages, code snippets, parameters](#developers--collect-error-messages-code-snippets-parameters)
  - [Data Analysts — Extract data from multiple reports](#data-analysts--extract-data-from-multiple-reports)
  - [Other scenarios](#other-scenarios)
- [🚀 Quick Start](#-quick-start)
  - [⚡ 1-Second Launch](#-1-second-launch)
  - [🎮 Hotkeys](#-hotkeys)
  - [⚙️ Custom Configuration (Optional)](#️-custom-configuration-optional)
  - [📋 System Requirements](#-system-requirements)
- [❓ FAQ \& Clarifications](#-faq--clarifications)
  - [Q: Need admin rights?](#q-need-admin-rights)
  - [Q: Does it upload my data?](#q-does-it-upload-my-data)
  - [Q: Will it hog resources?](#q-will-it-hog-resources)
  - [Q: Mac/Linux support?](#q-maclinux-support)
  - [Q: Does it cost?](#q-does-it-cost)
  - [What It's NOT](#what-its-not)
- [⚖️ License](#️-license)


## 💭 Our Philosophy

> **We're not making you work faster—we're protecting your focus.**

Most tools try to optimize surface-level speed. PickPaste is different.

We protect what matters: **your concentration, your flow state, your satisfaction completing work.**

This isn't just about saving time. **It's about preserving what's most valuable in your career: your attention.**


## ⚡ Problem → Solution → Results

### The Problem

Every day, millions of people repeat the same cycle:

**Find info → Switch window → Fill info → Switch again → Repeat 50 times...**

Research shows **every window switch takes 15-25 seconds to recover focus**. A task that seems 10 minutes actually takes 25—with 15 wasted on switching. Your attention gets shattered.

### Our Solution

```
❌ Traditional: find→switch→fill | find→switch→fill | find→switch→fill  [broken workflow]
✅ PickPaste: find→find→find | switch once | fill→fill→fill  [continuous flow]
```

**Core logic**: Collect all information first, then complete all work. No interruptions.

### Results

| Metric | Traditional | PickPaste |
|--------|-----------|----------
| Complete 10 data entries | 20+ minutes | 3-4 minutes |
| Window switches | 20+ times | 1 time |
| Focus recovery moments | 15+ times | 0 times |
| Work satisfaction | 😫 Drained | 😎 Smooth |


## 💡 What This Gets You

### 💪 Efficiency Boost 200%+
Not just speed, but **protecting your flow state**. Work becomes continuous and smooth.

### 🧠 Cognitive Load Drops Dramatically
Stop asking "where am I?" and "what's next?". Just focus on the current task.

### 💨 Zero Learning Cost
Install and use immediately. No complex UI, no steep learning curve.

### ⚡ Truly Lightweight
Memory usage <10MB, completely offline, zero tracking.

### 🎯 Minimalist Philosophy
Does one thing perfectly. Not a bloated "clipboard manager".


## 👥 Who Loves This & How It Helps

### Sales/Operations — Extract info from multiple sources
**Traditional**: See email → copy → open spreadsheet → paste → back to email (repeat 50+ times)  
**PickPaste**: See all emails and copy them → switch to spreadsheet → continuous paste ✨

### Editors/Journalists — Organize multi-source research
**Traditional**: Research webpage → write in document → research again → switch back… workflow destroyed  
**PickPaste**: Gather all materials first → switch to document → write continuously without breaks ✨

### Developers — Collect error messages, code snippets, parameters
**Traditional**: Check log → copy → paste to editor → check log again… constant switching  
**PickPaste**: Collect all info from multiple sources → switch to code → use everything at once ✨

### Data Analysts — Extract data from multiple reports
Save 10 minutes of focus time from what used to be 15 minutes of window switching.

### Other scenarios
- Form filling (webpage fields → spreadsheet)
- Excel data entry (work while listening to music)
- Content curation (PDFs, emails, chats → document)
- Any job involving "moving text between windows"


## 🚀 Quick Start

### ⚡ 1-Second Launch

1. **Download**  [![Download PickPaste](https://img.shields.io/badge/Download-PickPaste-blue)](https://github.com/pilot-ball/PickPaste/releases/latest)

2. Double-click PickPaste.exe to use it immediately. No installation, configuration, or computer restart is required.


### 🎮 Hotkeys

| Shortcut | Function |
|----------|----------
| `Ctrl + Alt + C` | Collect current clipboard |
| `Ctrl + Alt + V` | Paste next item |
| `Ctrl + Alt + X` | Clear queue |
| `Ctrl + Alt + Q` | Show queue status |

Also supports mouse side buttons (XButton1/XButton2) for the same actions.

### ⚙️ Custom Configuration (Optional)

Make sure config.ini is in the same folder as PickPaste.exe, then edit config.ini:

```ini
[Hotkeys]
EnableKeyboard=true # Enable keyboard shortcuts Ctrl+Alt+C, Ctrl+Alt+V, Ctrl+Alt+X, Ctrl+Alt+Q EnableXButton=true # Enable mouse side buttons
EnableXButton=true # Enable mouse side buttons
```
To disable keyboard shortcuts or mouse side buttons, use the following settings:
```ini
[hotkeys]
EnableKeyboard=false # Disable keyboard shortcuts Ctrl+Alt+C, Ctrl+Alt+V, Ctrl+Alt+X, Ctrl+Alt+Q
EnableXButton=false # Disable mouse side buttons
```
You can remap any action to match your preferred workflow
```ini
[hotkeys]
# Custom key combinations (Format: Modifier+Modifier+Key)
HotkeyCollect=Ctrl+Alt+C  # Collect selected text into queue
HotkeyPaste=Ctrl+Alt+V    # Paste next item from queue
HotkeyClear=Ctrl+Alt+X    # Clear current text queue
HotkeyStatus=Ctrl+Alt+Q   # Display queue status in console
```
Save the file and run PickPaste.exe again for the changes to take effect. No computer restart is required.

### 📋 System Requirements

| Item | Requirement |
|------|-------------
| **OS** | Windows 10 / Windows 11 |
| **PowerShell** | 5.0+ (included with Windows) |
| **Permissions** | Standard user rights |
| **Memory** | <10 MB |
| **Disk** | <2 MB |

**Bottom line**: Windows 10 or newer? PickPaste works. Completely zero dependencies.


## ❓ FAQ & Clarifications

### Q: Need admin rights?
A: No. Standard user permissions work fine.

### Q: Does it upload my data?
A: Completely offline. Zero cloud, zero tracking.

### Q: Will it hog resources?
A: Memory usage <10MB. You won't even notice it's running.

### Q: Mac/Linux support?
A: Windows-only for now.

### Q: Does it cost?
A: Completely free. MIT license.

### What It's NOT

- ❌ **Not a clipboard history manager** — doesn't store history, not bloated
- ❌ **Not a cloud tool** — completely local and private
- ❌ **Not a complex app** — just one function, done perfectly

**It is**: A laser-focused efficiency tool.


## ⚖️ License

MIT License — [See LICENSE file](LICENSE)

Free to use, modify, and share.

