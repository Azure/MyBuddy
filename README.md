# My Buddy

<img src="portal/buddy-logo.svg" alt="My Buddy logo" width="72">

**Your work lives everywhere, your attention shouldn't have to.**

My Buddy brings attention-worthy work from email, Teams chats, pull requests, and document requests into a personal portal. Review what needs you, approve a specific task, and continue the work in your existing native GitHub Copilot CLI.

Buddy remembers the link between each work item and its Copilot conversation. It is an attention and session bridge, **not another AI chat client or an AI-request proxy**.

> **Internal engineering pilot.** This is a Windows source release, not a hosted service or standalone installer. Each person uses their own accounts, permissions, local checkouts, and Microsoft Scout installation. Current limitations are listed below.

## What it does

- Collects a concise view of work that may need your attention, using a scan window capped at the last seven days.
- Retains work items across scans until you explicitly mark them done or dismiss them.
- Uses source checkpoints and receipts to reduce repeated triage; incomplete coverage is reported rather than presented as complete.
- Hands an approved task to native Copilot CLI once, with your chosen checkout and available agent.
- Reopens or focuses the **same saved conversation** without resubmitting its original task.
- Separates task approval from approval to publish messages, comments, or code.

### Source coverage

| Source | Current scope |
| --- | --- |
| Outlook | Your exact **Inbox/Important** folder only. In-window messages are paginated; 50 is a page size, not a total scan limit. |
| Microsoft Teams | Chats. Meetings, transcripts, and channels are not included. |
| Azure DevOps | Authored and review-related PRs and comment activity in explicitly configured repositories, subject to collector limits. |
| GitHub | Optional PR reads for your configured login and repositories, subject to collector limits. Disabled until configured. |
| Office documents | New-to-Buddy feedback, mention, and review/input requests discovered through Important email and Teams. Not an exhaustive file audit. |

Known document items, including closed ones, are not reopened just to refresh comments during a scan. Incident-notification items are excluded by the default briefing policy. A scan does not send replies, resolve comments, merge PRs, or complete work for you.

## Requirements

| Dependency | Requirement |
| --- | --- |
| Operating system | Windows; private portal state uses Windows-user DPAPI. |
| PowerShell | 7.2 or newer. Use PowerShell 7, not Windows PowerShell 5.1. |
| Node.js | 22 or newer for Buddy; 24 is recommended. Your Copilot CLI may require a newer minimum. |
| Git and Azure CLI | Required for the initial Azure DevOps-based setup and repository access. |
| GitHub CLI | Required if enabling GitHub PR reads; authenticate with your own account. |
| GitHub Copilot CLI | A compatible installation with native session flags and experimental extension SDK support, plus your own Copilot entitlement. |
| Microsoft Scout | Your own access and Microsoft 365 sign-in for email, Teams, document discovery, and scheduling. |
| Windows Terminal | Recommended for named tabs and session navigation. |

You also need access to the repositories you configure and an existing local checkout where Copilot can work. Custom agents and MCP servers must already be installed and authenticated; none are provisioned by this repository.

Follow your organization's approved software installation and sign-in procedures. Setup detects capabilities but does **not** verify model entitlement or prove every service is authenticated.

## Quick start

### 1. Clone the source

Open PowerShell 7 in a permanent parent directory you own:

```powershell
git clone https://github.com/Azure/MyBuddy.git
Set-Location .\MyBuddy
```

Repository access is required. This checkout contains clean source and templates, not another person's configured installation.

### 2. Create your personal configuration

```powershell
.\Setup-Buddy.ps1
```

Have these details ready: your Azure DevOps organization, project, repository name, tenant ID, user email, existing checkout path, and personal Copilot CLI profile. Choose an entitled model and optionally configure GitHub reads or an existing agent. If you do not know your Important folder ID, leave it empty for Scout to resolve.

The initial setup requires an Azure DevOps repository; GitHub is an optional additional source. Selecting a checkout tells Buddy where to launch work, not which branch to switch to.

Setup creates four personal files:

| File | Purpose |
| --- | --- |
| `buddy.config.json` | Source scope, identities, and requested schedule. |
| `buddy.agent.json` | Local checkouts, CLI profile, handlers, and terminal defaults. |
| `Scout-Setup.txt` | Instructions for registering this installation in your Scout. |
| `Scan-Automation.txt` | Your proposed daily/on-demand scan instructions. |

These files are ignored by Git. Setup refuses to overwrite existing personal configuration. It does not install dependencies, sign you in, start a scan, register an automation, or grant CLI permissions. A desktop shortcut is created only if requested.

### 3. Register the scan in Scout

Open the generated `Scout-Setup.txt` and follow its instructions in your own Scout. It guides Scout through resolving your exact Important folder, registering a personal skill, and creating or reusing **one daily/on-demand automation** after your approval.

The suggested schedule is 09:00 in the time zone selected during setup. Confirm the effective time zone before enabling it.

**Copying the repository or setting `schedule.enabled` does not register an automation.** Registration must use Scout's supported tools or UI. Scheduled scans require your machine to be awake, online, and running Scout.

### 4. Open Buddy and run your first scan

```powershell
.\Start-BuddyPortal.ps1 -Open
```

This opens the authenticated local portal. In Scout, use **Run now** on your registered My Buddy automation for a full on-demand scan.

> **Important:** The portal's **Scan for updates** button starts PR collection and queues Microsoft 365 work. It cannot directly start Scout in this version. Use **Run now in Scout** to execute the Microsoft 365 portion; queued does not mean running.

## Everyday workflow

1. Review the attention list and its coverage notes. Older work remains available even after it falls outside the current scan window.
2. Choose **Work on this**, describe the task, select the checkout and handler, and approve the exact preview.
3. Work in the visible native Copilot CLI. The approved first prompt is delivered once; subsequent messages, tool calls, and model choices belong to Copilot.
4. Use **Continue conversation** to return to the linked session. Buddy does not create a replacement conversation or replay the task.
5. When finished using the CLI, enter **`/exit`** in Copilot's chat input and wait for shutdown. Mark the work done yourself when appropriate.

New-user defaults use native permission prompts, interactive mode, ordinary context, and no concurrent sessions in a shared checkout. **Full tools** is an explicit per-task choice that persists for that exact session. Installed XFE-* handlers are offered where available; no team-specific agent is bundled.

If you opt into concurrent sessions, they share the checkout's files and active branch. You coordinate edits and branches; Buddy does not create worktrees, switch branches, or provide checkout isolation.

## Privacy, permissions, and publication

The portal is loopback-only and uses device-local authentication. Portal state is encrypted at rest for the current Windows user. Source access still goes through your configured services, and native Copilot uses its normal model and tool connections; this is **not an offline or air-gapped system**.

| Data | Location |
| --- | --- |
| Personal configuration and generated registration instructions | Your installed Buddy folder; excluded from Git. |
| Encrypted portal state | `%LOCALAPPDATA%\MyBuddy\portal` |
| Terminal bindings and protected work titles | `%LOCALAPPDATA%\MyBuddy\terminals` |
| Task state and native conversation history | Locations selected in `buddy.agent.json` |

Use only data your organization permits you to process. DPAPI is not permission to cache restricted content. Cloud Office reads must use authorized grounded access; do not download or parse protected files to bypass usage restrictions.

**Approving a task does not approve publication.** Sending email or Teams messages, posting or resolving comments, pushing code, and merging require a separate exact preview and explicit approval. These instructions are best-effort guidance, not a sandbox or a guarantee that every downstream write is technically blocked. Native CLI/MCP permissions and organizational policies still matter.

Never commit personal configuration, credentials, mailbox folder IDs, registration IDs, work inventories, conversation history, logs, or recordings. Share the clean repository, not a folder that has already been configured for someone else.

## Known limitations and troubleshooting

| Symptom or limitation | What to do |
| --- | --- |
| Copilot remains running after closing its tab | Windows app execution aliases can escape the terminal's cleanup job. **Automatic cleanup is not guaranteed.** Use `/exit` inside Copilot and wait for shutdown before closing the tab. |
| Continue reports a leftover process | Do not delete history or launch a duplicate. Cleanup needs explicit approval and verification of the exact process/session identity. |
| Mark as done is disabled | It stays blocked while a native runtime is active, including when waiting for input. Exit the runtime first; closing it does not automatically complete the work item. |
| Microsoft 365 scan remains queued | Run the registered automation using **Run now in Scout**. The portal has no supported direct Scout trigger. |
| Setup reports an incompatible CLI | Use an organization-approved CLI version with the required flags and extension SDK support. There is no hidden fallback or automatic permission change. |
| Important folder cannot be resolved | Resolve the exact folder in your own mailbox with Scout. Do not substitute the whole inbox. |
| Another installation owns the live portal | Use one installed Buddy folder per Windows account. Do not run setup in a second source checkout just to inspect it. Stop your own portal normally before moving or upgrading. |

There is no hosted deployment, EXE installer, automatic updater, centrally managed multi-user service, dedicated bug tracker, or guaranteed missed-schedule recovery in this pilot. The current Teams scope is chats, not meetings or channels.

### Read-only setup diagnostics

Copy the answer template, fill in your own values, then run Doctor:

```powershell
Copy-Item .\distribution\setup.answers.example.json .\setup.answers.json
# Edit setup.answers.json before continuing.
.\Setup-Buddy.ps1 -Doctor -AnswersFile .\setup.answers.json
```

Doctor does not write configuration. To apply those reviewed answers to a fresh installation:

```powershell
.\Setup-Buddy.ps1 -NonInteractive -AnswersFile .\setup.answers.json
```

For all setup options:

```powershell
Get-Help .\Setup-Buddy.ps1 -Full
```

## Repository guide

| Area | Responsibility |
| --- | --- |
| [Setup-Buddy.ps1](Setup-Buddy.ps1) and [distribution](distribution) | Per-user setup, validation, and portable onboarding templates. |
| [portal](portal) | Local Node.js server, browser UI, scan coordination, and encrypted state integration. |
| `Get-Buddy*PullRequests.ps1` and related core modules | Read-only Azure DevOps and GitHub PR collection. |
| [Scan.Worker.txt](Scan.Worker.txt) | Microsoft 365 scan procedure executed by Scout. |
| [scout-integration.txt](scout-integration.txt) | Source, retention, approval, and session handoff contracts. |
| `Buddy.NativeTask.*`, `Buddy.Terminal.*`, and [Open-BuddySession.ps1](Open-BuddySession.ps1) | Approved first-task delivery and exact native session navigation. |
| [Export-Buddy.ps1](Export-Buddy.ps1) | Optional allowlisted clean ZIP export; never packages the entire installed folder. |
| [HELP.txt](HELP.txt) | Detailed pilot operating instructions. |

This repository is the shareable source distribution. Private installation data and test fixtures are not included. Keep changes free of personal work examples and verify behavior in an isolated setup rather than resetting a live user's state.
