# Security scope

This library runs inside the game with the player's account privileges. Trust the source revision and the
local compiler before installing. Review a full commit SHA, check out that revision, verify `SHA256SUMS`,
and build locally. A manifest from the same untrusted source is not a signature or an independent trust anchor.
The installer does not download code or change macOS security settings and refuses to run as root.

## Controls

* Build and source checks happen before the executable is replaced. Backups are created exclusively from a
  private copy; an existing backup is never overwritten. Caught publish errors and normal termination
  signals trigger restoration. A lock directory excludes concurrent managed install/uninstall operations.
* Uninstall verifies saved content hashes and refuses modified or symbolic-linked managed files.
* No code opens a diagnostic file path. The library only writes to existing stderr when `FUSIONFIX_LOG=1`.
* Zeroing weak references track objects without extending their lifetime. Hook operations use strong local
  snapshots; added view mutations and shared object state are confined to the main thread.
* Hooks apply only to the installed `Sam2017_real` executable name. The full method set is checked before
  installation. Rendering counters are atomic and background repairs do not synchronously wait on the UI.

## Limits

The installer assumes the user's Steam directory, source checkout, PATH and toolchain are trusted and are
not being modified concurrently by another program. This is not a privileged installer or a boundary
against malware already running as the same user. Filesystem power failures or uncatchable termination
may require recovery using the preserved original backup. An executable-name check is a scope guard,
not authentication of a process or its content.

This fork does not audit or harden the original game engine, Steam, Rosetta, Workshop mods or network
protocols. Automated tests cover controlled installation failures and modeled object lifetimes, not the
real engine. Background repairs are asynchronous: first-frame timing and repeated fullscreen transitions
must be validated in gameplay before treating this fork as a tested replacement for the upstream fix.

Report reproducible problems through this fork's GitHub issues without including account data, saves or
private paths in public diagnostic output.
