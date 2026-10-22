# GEMINI.md - Agent Safety & Development Guidelines for Reglaze

> **CRITICAL SAFETY DIRECTIVE: HOST OS PROTECTION & HITL VERIFICATION**
>
> `reglaze` is an OS deployment and automation tool designed for fresh bare-metal and re-imaging workflows. Its scripts manipulate Windows registry hives, junctions, BitLocker, Explorer/Taskbar settings, and system power states.
>
> **AGENTS MUST NEVER RUN OR TEST REGLAZE SCRIPTS DIRECTLY AGAINST THE HOST WINDOWS INSTALLATION.**

---

## Safety Guidelines & Operational Constraints

1. **Host Execution Prohibition:**
   - **DO NOT** execute scripts from `src/runner/`, `data/windows/`, or deployment pipelines (`Start-MachineBootstrap.ps1`, `Apply-WindowsSettings.ps1`, `taskbar-system-tray.ps1`, etc.) directly on the host machine.
   - **DO NOT** execute commands or scripts that invoke `Restart-Computer`, `shutdown`, or mutate registry entries (`HKCU:`, `HKLM:`).
   - **DO NOT** create directory junctions pointing to real system directories (`C:\Program Files`, `C:\ProgramData`, etc.) or re-arm BitLocker volumes on the host.

2. **Sandbox Awareness:**
   - The execution sandbox only restricts network and file write boundaries outside workspace directories. **It does NOT intercept or virtualize Windows Registry, Explorer state, or system power commands.**
   - Running inside the sandbox does not protect the host OS against PowerShell cmdlets targeting Windows configuration.

3. **Development & Unit Experiments (Human-in-the-Loop):**
   - Development tests must strictly use mocks, `-Simulation` flags, or temporary scratch folders (`tests/temp_*`).
   - Any live experiment or test requiring real Windows integration must be presented to the user for explicit review and run manually by the user (HITL) in an isolated virtual machine.

---

## Phased Testing Strategy

Agents must follow the three-tiered testing roadmap in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md):

1. **Tier 1 (Milestones 3 & 4 - Active Development):**
   - In-repo mocks, `-Simulation` flags, and temporary scratch paths (`tests/temp_*`).
   - Human-in-the-loop review for isolated, read-only low-level API queries.
   - Zero execution of provisioning or system scripts against the host OS.

2. **Tier 2 (Pre-Milestone 5 - Staged Practical Validation):**
   - Non-critical target deployment passes run externally by the user to identify real-world timing and hardware edge cases.

3. **Tier 3 (Milestone 5 - Automated VM Validation):**
   - Dedicated local Hyper-V test VM (`Reglaze-TestVM`) with dual virtual disks (`C:` ephemeral OS, `D:` preserved data).
   - Automation via **PowerShell Direct** (`Invoke-Command -VMName`, `Copy-Item -ToSession`).
   - Automatic checkpoint rollback (`Restore-VMSnapshot`) for continuous integration testing.

---

## Human-in-the-Loop (HITL) Testing Protocol & Comment Standard

To ensure that low-level and potentially destructive code (BitLocker, Registry, AutoLogon, Reboot, Junctions, Service APIs) is rigorously tested without endangering the host environment, and to ensure testing progress remains **durable across system interruptions, unexpected reboots, or agent context resets**, all agents must follow this structured HITL protocol:

### Standardized Code Annotation Schema
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

### Batch Interaction Lifecycle
1. **Identification & Annotation:** Agent identifies all unvalidated low-level code blocks, tags them with `[HITL-ID]` annotations in code, and logs them in [docs/HITL_TESTING.md](docs/HITL_TESTING.md).
2. **Batched Presentation:** The agent presents outstanding HITL tests as a numbered batch in the turn response, with copy-pasteable snippets and clear instructions.
3. **Batch Result Processing:** The user returns results (which may be partial). The agent parses the returned outputs, updates the `[HITL-LAST-RESULT]`, `[HITL-STATUS]`, `[HITL-PATTERN]`, or `[HITL-AVOID]` tags in the corresponding files, and records any necessary code fixes.
4. **Iterative Progression:** The agent delivers code fixes and returns the updated roster of remaining tests until all are marked `VERIFIED` or the user explicitly tables them for the next testing session.
