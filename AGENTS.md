# AGENTS.md - Development & Safety Guidelines for Reglaze

> **CRITICAL SAFETY DIRECTIVE: HOST OS ISOLATION & HUMAN-IN-THE-LOOP (HITL)**
> 
> `reglaze` is an operating system provisioning and workstation deployment automation tool designed to configure and re-image Windows installations from bare metal. Because its scripts interact with low-level Windows features (Registry, BitLocker, Explorer, Taskbar, AutoLogon, Reboot, and Directory Junctions), **AGENTS MUST NEVER RUN OR TEST REGLAZE SCRIPTS DIRECTLY AGAINST THE HOST WINDOWS INSTALLATION.**

---

## 1. Absolute Constraints for Agents

1. **NEVER Execute Live Provisioning or System Scripts on Host:**
   - **DO NOT** execute `Start-MachineBootstrap.ps1`, `Apply-WindowsSettings.ps1`, `taskbar-system-tray.ps1`, `explorer-folder-options.ps1`, `performance-power.ps1`, or any script from `data/windows/` or `src/runner/` against the host machine.
   - **DO NOT** execute commands or scripts that call `Restart-Computer`, `shutdown`, or logoff routines.
   - **DO NOT** execute commands or cmdlets that mutate Windows registry hives (`HKCU:`, `HKLM:`), system services, or Windows Explorer configurations.
   - **DO NOT** invoke BitLocker management cmdlets (`Enable-BitLockerAutoUnlock`, `Unlock-BitLocker`, etc.) or PSWindowsUpdate on the host machine.

2. **Terminal Sandbox Limitation Awareness:**
   - The terminal sandbox isolates network access and prevents writing outside the designated workspace boundaries, **but it does NOT virtualize or protect the Windows Registry, Explorer process, or system power APIs (`Restart-Computer`)** when running native PowerShell commands.
   - Never assume that running in the sandbox makes a system-modifying PowerShell cmdlet safe to execute on the host.

3. **Testing & Experimentation Policy (HITL Required):**
   - **Automated Tests:** Any automated tests run by an agent must strictly use mocks, `-Simulation` flags, or isolated temporary directories (e.g., `tests/temp_*`) that do not interact with live registry or system settings.
   - **No Autonomous Live Testing:** Agents must never run tests that execute real registry alterations, driver installations, or reboot sequences.
   - **Human-in-the-Loop (HITL) for Unit Experiments:** If a small unit experiment or live Windows interaction is needed during development:
     - The agent **must not** run it autonomously.
     - The experiment must be formulated as a proposed snippet and presented to the user for explicit review.
     - The user must decide whether to run it manually or execute it inside an isolated test VM (e.g., Hyper-V / Proxmox).

4. **Preserve User Environment:**
   - Always treat the host machine as a development workstation, never as a test target for OS provisioning.

---

## 2. Phased Testing Strategy

Agents must adhere to the three-tiered testing roadmap defined in [ARCHITECTURE.md](docs/ARCHITECTURE.md):

1. **Tier 1 (Milestones 3 & 4 - Active Development):**
   - In-repo mocks, `-Simulation` flags, and scratch paths (`tests/temp_*`).
   - Human-in-the-loop review for isolated, read-only low-level API queries.
   - Zero execution of provisioning scripts on the developer workstation.

2. **Tier 2 (Pre-Milestone 5 - Staged Practical Validation):**
   - Non-critical target deployment runs performed externally by the user to identify real-world timing and hardware edge cases.

3. **Tier 3 (Milestone 5 - Automated VM Validation):**
   - Dedicated local Hyper-V test VM (`Reglaze-TestVM`) with dual virtual disks (`C:` ephemeral OS, `D:` preserved data).
   - Agent-driven automation via **PowerShell Direct** (`Invoke-Command -VMName`, `Copy-Item -ToSession`).
   - Automatic checkpoint rollback (`Restore-VMSnapshot`) for reproducible end-to-end deployment verification.

---

## 3. Human-in-the-Loop (HITL) Testing Protocol & Comment Standard

To ensure that low-level and potentially destructive code (BitLocker, Registry, AutoLogon, Reboot, Junctions, Service APIs) is rigorously tested without endangering the host environment, and to ensure testing progress remains **durable across system interruptions, unexpected reboots, or agent context resets**, all agents must follow this structured HITL protocol:

### 3.1 Standardized Code Annotation Schema
Every low-level manipulation point in code or test suites that requires real Windows interaction must be annotated with a grep-friendly block using the following fields:

```powershell
# =============================================================================
# [HITL-ID]: HITL-M3-01 (unique, sequential identifier per milestone)
# [HITL-TARGET]: Component / Cmdlet / Subsystem (e.g., Enable-BitLockerAutoUnlock)
# [HITL-STATUS]: PENDING | IN_PROGRESS | VERIFIED | TABLED
# [HITL-DESCRIPTION]: Explanation of what needs validation and risks involved
# [HITL-TEST-SNIPPET]:
#   # Isolated, non-destructive or VM-executable snippet the user should run
#   # Example: Get-BitLockerVolume -MountPoint D: | Select-Object VolumeStatus, KeyProtector
# [HITL-LAST-INPUT]: Parameters/arguments used in the latest test run
# [HITL-LAST-RESULT]: Observed output, error message, or exit code from the last test run
# [HITL-PATTERN]: Verified working command pattern to emulate in production code
# [HITL-AVOID]: Approaches/cmdlets that failed or caused issues (and why)
# =============================================================================
```

### 3.2 Batch Interaction Lifecycle
To minimize testing round-trips and optimize developer time:
1. **Identification & Annotation:** Agent identifies all unvalidated low-level code blocks, tags them with `[HITL-ID]` annotations in code, and logs them in [docs/HITL_TESTING.md](docs/HITL_TESTING.md).
2. **Batched Presentation:** The agent presents outstanding HITL tests as a numbered batch in the turn response, with copy-pasteable snippets and clear instructions.
3. **Batch Result Processing:** The user returns results (which may be partial). The agent parses the returned outputs, updates the `[HITL-LAST-RESULT]`, `[HITL-STATUS]`, `[HITL-PATTERN]`, or `[HITL-AVOID]` tags in the corresponding files, and records any necessary code fixes.
4. **Iterative Progression:** The agent delivers code fixes and returns the updated roster of remaining tests until all are marked `VERIFIED` or the user explicitly tables them for the next testing session.
