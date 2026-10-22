# Host OS Isolation & HITL Testing Rule

## Context & Scope
This rule applies across the entire `reglaze` repository.

## Directives
1. **Never run deployment or provisioning scripts against the host OS.**
   `reglaze` targets bare-metal provisioning and system-level configuration (Explorer, Taskbar, BitLocker, AutoLogon, Reboot). Running these scripts on the developer workstation can alter user preferences or trigger an unexpected system restart (`Restart-Computer`).
2. **Terminal Sandbox Limitation:**
   The terminal sandbox restricts file paths and network access, but does NOT virtualize or protect the host Windows Registry, running processes, or reboot APIs. Do not assume sandboxing prevents host modifications.
3. **HITL Required for Unit Experiments:**
   - Small unit experiments during development that touch real Windows subsystems must be reviewed and executed by the user in a human-in-the-loop (HITL) manner.
   - Autonomous tests executed by agents must be strictly mocked, simulated (`-Simulation`), or run against synthetic scratch folders.
