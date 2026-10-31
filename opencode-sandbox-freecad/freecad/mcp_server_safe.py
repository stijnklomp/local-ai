#!/usr/bin/env python3
"""Safe entry point for the FreeCAD AI MCP server over Streamable HTTP.

Starts FreeCAD's GUI with the freecad-ai workbench and serves MCP at /mcp.
Only an explicit allowlist of structured modeling tools is served. User
extension tools, macros-as-tools, skill execution and code execution are
removed, and path-writing tools are restricted to the project directory.

Usage:
    MCP_AUTH_TOKEN=... FREECAD_AI_WRITE_ROOT=/path/to/project \
        FreeCAD.AppImage /absolute/path/to/freecad/mcp_server_safe.py

The launcher normally supplies the server configuration through the
environment; these variables win over FreeCAD AI's saved settings:

    MCP_AUTH_TOKEN          bearer token required from clients (required)
    MCP_HOST                listen address (must stay loopback)
    MCP_PORT                listen port (default 3000)
    MCP_ALLOWED_HOSTS       comma-separated Host header allowlist
    FREECAD_AI_WRITE_ROOT   directory that export_model/capture_viewport may
                            write under (required; the mounted project dir)

This file does not modify the freecad-ai workbench installation.
"""

# FreeCAD must be imported before the workbench package is importable.
import FreeCAD

import inspect
import os
import sys

if FreeCAD.ActiveDocument is None:
    FreeCAD.newDocument("Unnamed")

# Explicit allowlist: only these structured tools are served. Anything else
# the registry exposes -- user extension tools, macros-as-tools, skill tools,
# run_fem_analysis, or a future upstream code-execution tool -- is removed.
# This is deliberately fail-closed: a new upstream tool is not exposed until
# it is reviewed and added here.
ALLOWED_TOOLS = frozenset(
    """
    add_assembly_joint
    add_part_to_assembly
    boolean_operation
    capture_viewport
    chamfer_edges
    create_assembly
    create_body
    create_datum_line
    create_datum_plane
    create_enclosure_lid
    create_inner_ridge
    create_primitive
    create_sketch
    create_snap_tabs
    create_spreadsheet
    create_variable_set
    create_wedge
    delete_object
    describe_model
    duplicate_object
    edit_sketch
    edit_spreadsheet
    edit_variable_set
    export_model
    fillet_edges
    get_document_state
    linear_pattern
    list_documents
    list_edges
    list_faces
    loft_sketches
    measure
    mirror_feature
    modify_property
    multi_transform
    pad_sketch
    pocket_sketch
    polar_pattern
    read_spreadsheet
    read_variable_set
    redo
    report_skill_params
    revolve_sketch
    scale_object
    section_object
    select_geometry
    set_expression
    set_view
    shell_object
    sweep_sketch
    switch_document
    transform_object
    undo
    undo_history
    zoom_object
    """.split()
)
REQUIRED_TOOLS = frozenset(
    ("create_primitive", "list_documents", "get_document_state", "export_model")
)
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1"}


def _find_workbench_dir():
    """Return the freecad-ai workbench directory, or None if not installed."""
    for getter_name in ("getUserAppDataDir", "getResourceDir"):
        getter = getattr(FreeCAD, getter_name, None)
        if getter is None:
            continue
        try:
            base = getter()
        except Exception as exc:
            print(
                "WARNING: FreeCAD.%s() failed: %s" % (getter_name, exc),
                file=sys.stderr,
                flush=True,
            )
            continue

        candidate = os.path.join(base, "Mod", "freecad-ai")
        if os.path.isdir(candidate):
            return candidate
    return None


_workbench_dir = _find_workbench_dir()
if _workbench_dir is None:
    print(
        "ERROR: freecad-ai workbench not found. Looked for 'Mod/freecad-ai' "
        "under FreeCAD.getUserAppDataDir() and FreeCAD.getResourceDir(). "
        "Install the freecad-ai workbench (expected tag v0.33.0-alpha) or add "
        "its directory to FreeCAD's Mod folder, then retry.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

if _workbench_dir not in sys.path:
    sys.path.insert(0, _workbench_dir)

from freecad_ai.tools.executor_utils import QtMainThreadToolExecutor
from freecad_ai.tools.registry import ToolResult
from freecad_ai.tools.setup import create_default_registry

_removed_tools = []


def _make_write_guard(original, arg_name, root):
    """Wrap a tool handler so *arg_name* must resolve under *root*."""
    root_real = os.path.realpath(os.path.expanduser(root))

    def guarded(*args, **kwargs):
        target = kwargs.get(arg_name)
        if target is None:
            try:
                bound = inspect.signature(original).bind_partial(*args, **kwargs)
                target = bound.arguments.get(arg_name)
            except (TypeError, ValueError):
                target = None
        if not target:
            return ToolResult(
                success=False,
                output="",
                error="%s is required" % arg_name,
            )

        real = os.path.realpath(
            os.path.abspath(os.path.expanduser(str(target)))
        )
        try:
            inside = os.path.commonpath([root_real, real]) == root_real
        except ValueError:
            inside = False
        if not inside:
            return ToolResult(
                success=False,
                output="",
                error=(
                    "Refusing to write outside the allowed project directory "
                    "%s: %s" % (root_real, target)
                ),
            )
        return original(*args, **kwargs)

    return guarded


def _guard_writes(registry, root):
    """Restrict path-writing tools to *root* (FREECAD_AI_WRITE_ROOT)."""
    for tool_name, arg_name in (
        ("export_model", "filename"),
        ("capture_viewport", "filepath"),
    ):
        tool = registry.get(tool_name)
        if tool is not None:
            tool.handler = _make_write_guard(tool.handler, arg_name, root)


def _safe_backend(write_root):
    """Build the allowlisted registry and the Qt main-thread executor."""
    registry = create_default_registry(include_mcp=False)

    for tool_name in list(registry._tools):
        if tool_name not in ALLOWED_TOOLS:
            registry._tools.pop(tool_name, None)
            _removed_tools.append(tool_name)

    missing = [name for name in REQUIRED_TOOLS if name not in registry._tools]
    if missing:
        raise RuntimeError(
            "safe MCP server: required tool(s) missing from the registry: %s. "
            "Refusing to serve an unexpected toolset." % ", ".join(sorted(missing))
        )

    _guard_writes(registry, write_root)
    executor = QtMainThreadToolExecutor()
    executor.set_registry(registry)
    return registry, executor


import freecad_ai.mcp.gui_server as gui_server  # noqa: E402

get_server_controller = gui_server.get_server_controller
resolve_allowed_hosts = gui_server.resolve_allowed_hosts
resolve_auth_token = gui_server.resolve_auth_token
resolve_server_address = gui_server.resolve_server_address

# cfg=None: the environment variables documented above take precedence.
host, port = resolve_server_address(cfg=None)
allowed_hosts = resolve_allowed_hosts(cfg=None)
auth_token = resolve_auth_token(cfg=None)

if host not in LOOPBACK_HOSTS:
    print(
        "ERROR: refusing to bind the MCP server to non-loopback host %r. "
        "This server exposes FreeCAD tools and must stay on 127.0.0.1."
        % host,
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

if not auth_token:
    print(
        "ERROR: refusing to start the MCP server without MCP_AUTH_TOKEN. "
        "Set a bearer token; the launcher normally generates and exports one.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

write_root = os.environ.get("FREECAD_AI_WRITE_ROOT")
if not write_root:
    print(
        "ERROR: refusing to start the MCP server without FREECAD_AI_WRITE_ROOT. "
        "Set it to the project directory that export_model and "
        "capture_viewport may write under.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

controller = get_server_controller()
if controller.is_running():
    print(
        "ERROR: an MCP server is already running in this FreeCAD process. "
        "It may have been started by the toolbar with the unrestricted "
        "toolset. Close FreeCAD and start it through run-freecad-ai.sh.",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

# Reuse the process-wide controller so the toolbar reflects the safe server,
# but give it the filtered backend instead of the default unrestricted one.
# A previously stopped server may have left a built registry behind; clear it
# so the safe backend is actually used.
controller._backend_factory = lambda: _safe_backend(write_root)
controller._registry = None
controller._executor = None

url = controller.start(
    host,
    port,
    allowed_hosts=allowed_hosts,
    auth_token=auth_token,
)

# Post-start assertion: if a future freecad-ai ref changes the controller's
# private backend hook, fail closed instead of silently serving the default
# unrestricted registry.
served_registry = getattr(controller, "_registry", None)
unexpected = []
if served_registry is not None:
    unexpected = [
        name for name in served_registry._tools if name not in ALLOWED_TOOLS
    ]
if served_registry is None or unexpected:
    controller.stop()
    print(
        "ERROR: the running registry does not match the safe allowlist "
        "(unexpected: %s). Refusing to serve."
        % (", ".join(sorted(unexpected)) if unexpected else "registry unavailable"),
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

print("MCP server running on %s" % url, flush=True)
print(
    "Removed tools (%d): %s"
    % (
        len(_removed_tools),
        ", ".join(sorted(_removed_tools)) if _removed_tools else "none",
    ),
    flush=True,
)
print(
    "Write root: %s"
    % os.path.realpath(os.path.expanduser(write_root)),
    flush=True,
)
