# FreeCAD AI sandbox

Run OpenCode in a Docker Sandbox (`sbx`) and let it drive a FreeCAD 1.1 session on the host through the FreeCAD AI MCP server. FreeCAD stays on the host, so you watch the model change live; the agent runs in the sandbox.

## One-time setup

Run on the Debian host, from this directory:

```sh
./scripts/install-dependencies.sh   # skip if sbx is already installed
sbx login
sbx secret set-custom --host opencode.ai --env OPENCODE_API_KEY   # if you use opencode-go
./scripts/setup-freecad.sh
```

`setup-freecad.sh` finds the FreeCAD AppImage, installs `libfuse2t64` if needed, clones `freecad-ai` at `v0.33.0-alpha`, links it into FreeCAD's versioned `Mod` directory, generates the MCP token, registers the `freecad` MCP server with sbx, and syncs the OpenCode config. Changed host config files are backed up as `*.bak`.

If the AppImage is not under your home directory:

```sh
./scripts/setup-freecad.sh --appimage /path/to/FreeCAD.AppImage
```

## Run

On the host, from this directory:

```sh
./scripts/run-freecad-ai.sh ~/FreeCAD
```

First run:

1. Complete FreeCAD's first-run/versioned-config dialog.
2. Select the **FreeCAD AI** workbench once.
3. Open or create a `.FCStd` file.
4. The launcher then starts OpenCode in the sandbox.

The agent only sees documents already open in FreeCAD. It has no save/open tool: save the `.FCStd` yourself in FreeCAD; the agent can export STL/STEP into the project directory. FreeCAD AI is alpha, so save often.

## How it works

- FreeCAD and the `freecad-ai` addon run on the host.
- The safe MCP server listens on `127.0.0.1:3000/mcp` with a bearer token.
- Sandboxed OpenCode reaches it through the sbx MCP gateway as the `freecad` server. The kit does not allow direct access to host port 3000.
- The project directory is mounted in the sandbox, and model writes are restricted to it.
- Only an explicit allowlist of structured FreeCAD tools is served. Code execution, skills, user tools and macros are excluded.
- Do not use the FreeCAD AI toolbar's MCP button for sandbox work; it can start an unrestricted server.

## If something fails

```sh
./scripts/doctor-freecad.sh
```

- FreeCAD tools missing in an existing sandbox: `sbx mcp load freecad --sandbox freecad`
- 401 or token mismatch: `./scripts/setup-freecad.sh --rotate-token`, then restart FreeCAD and the sandbox.
- Hosted MCP gateway: `sbx settings set mcp.forceLocalGateway true && sbx daemon restart`, then rerun setup.
- FreeCAD 1.2 upgrade: rerun `./scripts/setup-freecad.sh`; the Mod path changes from `v1-1` to `v1-2`.
- `libfuse.so.2` error: `sudo apt install libfuse2t64`.
- Switching project directory: close FreeCAD and rerun the launcher; the write root is fixed when FreeCAD starts.

## Paths

- FreeCAD Mod (normally): `~/.local/share/FreeCAD/v1-1/Mod/freecad-ai`
- freecad-ai checkout: `~/.local/share/freecad-ai`
- MCP token: `~/.config/freecad-ai/mcp-token`
- Project: `~/FreeCAD`
