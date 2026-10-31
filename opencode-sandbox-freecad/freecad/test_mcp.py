#!/usr/bin/env python3
"""Dependency-free doctor for the FreeCAD AI MCP server.

Checks that the Streamable HTTP endpoint is reachable, authenticates with a
bearer token, completes the MCP handshake, lists tools, and verifies that
dangerous tools are not exposed.

Examples:
    python3 test_mcp.py
    python3 test_mcp.py --token-file ~/.config/freecad-ai/mcp-token
    python3 test_mcp.py --blocked-tools execute_code,run_macro,use_skill
    python3 test_mcp.py --expect-unauthorized
    python3 test_mcp.py --url http://127.0.0.1:3000/mcp --quiet

Normal mode requires a token. It is taken from --token, then --token-file,
then $XDG_CONFIG_HOME/freecad-ai/mcp-token or ~/.config/freecad-ai/mcp-token
when that file exists. --expect-unauthorized deliberately sends no token and
succeeds only when the server answers HTTP 401.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_URL = "http://127.0.0.1:3000/mcp"
DEFAULT_BLOCKED_TOOLS = (
    "execute_code,"
    "execute_code_headless,"
    "run_macro,"
    "run_skill_script,"
    "use_skill"
)
DEFAULT_REQUIRED_TOOLS = (
    "create_primitive,"
    "list_documents,"
    "get_document_state,"
    "export_model"
)
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PROTOCOL_VERSION = "2025-03-26"
CLIENT_NAME = "freecad-ai-doctor"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Check a FreeCAD AI MCP server, its bearer authentication, and "
            "the tools it exposes."
        )
    )
    parser.add_argument(
        "--url",
        default=DEFAULT_URL,
        help="Streamable HTTP endpoint (default: %(default)s)",
    )
    parser.add_argument(
        "--token",
        help="bearer token; overrides --token-file and the default token file",
    )
    parser.add_argument(
        "--token-file",
        help=(
            "file containing the bearer token (default: "
            "$XDG_CONFIG_HOME/freecad-ai/mcp-token or "
            "~/.config/freecad-ai/mcp-token when present)"
        ),
    )
    parser.add_argument(
        "--expect-unauthorized",
        action="store_true",
        help="send no Authorization header and require HTTP 401",
    )
    parser.add_argument(
        "--blocked-tools",
        default=DEFAULT_BLOCKED_TOOLS,
        help="comma-separated tools that must not be exposed (default: %(default)s)",
    )
    parser.add_argument(
        "--required-tools",
        default=DEFAULT_REQUIRED_TOOLS,
        help="comma-separated tools that must be exposed (default: %(default)s)",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress success output; errors are still printed",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="request timeout in seconds (default: %(default)s)",
    )
    return parser.parse_args(argv)


def default_token_file():
    """Return the first conventional token file that exists, or None."""
    candidates = []
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config_home:
        candidates.append(
            Path(xdg_config_home).expanduser() / "freecad-ai" / "mcp-token"
        )
    candidates.append(Path.home() / ".config" / "freecad-ai" / "mcp-token")
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def resolve_token(args):
    """Return (token, error). Explicit --token wins over any file."""
    if args.token is not None:
        return args.token, None

    if args.token_file:
        path = Path(args.token_file).expanduser()
    else:
        path = default_token_file()

    if path is None:
        return None, None

    try:
        token = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        return None, "cannot read token file %s: %s" % (path, exc)

    if not token:
        return None, "token file %s is empty" % path
    return token, None


def parse_blocked_tools(raw):
    return [name.strip() for name in raw.split(",") if name.strip()]


def build_headers(token=None, session_id=None, protocol_version=None):
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Connection": "close",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    if protocol_version:
        headers["MCP-Protocol-Version"] = protocol_version
    return headers


def post_message(url, message, token, timeout, session_id=None,
                 protocol_version=None):
    """POST one JSON-RPC message and return (status, headers, body bytes).

    HTTP error statuses are returned normally, not raised, so callers can
    distinguish 401 from other failures. Network errors still propagate.
    """
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers=build_headers(token, session_id, protocol_version),
        method="POST",
    )
    try:
        with _OPENER.open(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, exc.headers, exc.read()
        finally:
            exc.close()


def iter_sse_data(body):
    """Yield the data payload of each Server-Sent Event in body."""
    data_lines = []
    text = body.decode("utf-8", errors="replace")
    for line in text.splitlines():
        if line == "":
            if data_lines:
                yield "\n".join(data_lines)
                data_lines = []
            continue
        if line.startswith(":"):
            continue
        field, separator, value = line.partition(":")
        if not separator:
            continue
        if value.startswith(" "):
            value = value[1:]
        if field == "data":
            data_lines.append(value)
    if data_lines:
        yield "\n".join(data_lines)


def parse_response(body, content_type, expected_id):
    """Parse a JSON or SSE response and return the matching JSON-RPC object."""
    content_type = (content_type or "").lower()

    if "text/event-stream" in content_type:
        for data in iter_sse_data(body):
            try:
                message = json.loads(data)
            except json.JSONDecodeError:
                continue
            if isinstance(message, dict) and message.get("id") == expected_id:
                return message
        raise ValueError(
            "SSE stream ended without a response for id %s" % expected_id
        )

    text = body.decode("utf-8", errors="replace").strip()
    if not text:
        raise ValueError("empty response body")
    try:
        message = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(
            "response was not valid JSON: %s (body starts with %r)"
            % (exc, text[:200])
        )
    if not isinstance(message, dict):
        raise ValueError("response is not a JSON object")
    if message.get("id") != expected_id:
        raise ValueError(
            "response id %r did not match request id %r"
            % (message.get("id"), expected_id)
        )
    return message


def get_content_type(headers):
    return headers.get_content_type() if headers is not None else ""


def print_error(message):
    print("ERROR: " + message, file=sys.stderr)


def http_error_text(status, body):
    text = body.decode("utf-8", errors="replace").strip()
    if len(text) > 2000:
        text = text[:2000] + "... (truncated)"
    if text:
        return "HTTP %d: %s" % (status, text)
    return "HTTP %d (empty response body)" % status


def json_rpc_error_text(message):
    error = message.get("error")
    if not isinstance(error, dict):
        return None
    text = "JSON-RPC error %s: %s" % (
        error.get("code", "unknown"),
        error.get("message", "no message"),
    )
    data = error.get("data")
    if data is not None:
        text += " (data: %r)" % (data,)
    return text


def is_connection_refused(reason):
    if isinstance(reason, ConnectionRefusedError):
        return True
    if getattr(reason, "errno", None) in (61, 111):
        return True
    return "connection refused" in str(reason).lower()


def network_error_text(exc, url, timeout):
    reason = getattr(exc, "reason", exc)
    if is_connection_refused(reason):
        return "MCP server is not running at %s (connection refused)." % url
    if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
        return "request to %s timed out after %s seconds." % (url, timeout)
    return "cannot reach MCP server at %s: %s" % (url, reason)


def report_unauthorized(url):
    print_error(
        "HTTP 401 Unauthorized from %s: the bearer token is missing or wrong."
        % url
    )


def initialize_request():
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": CLIENT_NAME, "version": "1.0"},
        },
    }


def check_unauthorized(args):
    """Require the server to reject an unauthenticated initialize request."""
    try:
        status, headers, body = post_message(
            args.url,
            initialize_request(),
            token=None,
            timeout=args.timeout,
        )
    except Exception as exc:
        print_error(network_error_text(exc, args.url, args.timeout))
        return 1

    if status == 401:
        if not args.quiet:
            print(
                "OK: the server rejected an unauthenticated request with "
                "HTTP 401; bearer authentication is enforced."
            )
        return 0

    if 200 <= status < 300:
        print_error(
            "expected HTTP 401 but got HTTP %d: the server accepted an "
            "unauthenticated request, so authentication is not enforced."
            % status
        )
        return 1

    print_error(
        "expected HTTP 401 but got %s"
        % http_error_text(status, body)
    )
    return 1


def check_server(args, token, blocked_tools, required_tools):
    """Run initialize, notifications/initialized, and tools/list."""
    try:
        status, headers, body = post_message(
            args.url,
            initialize_request(),
            token=token,
            timeout=args.timeout,
        )
    except Exception as exc:
        print_error(network_error_text(exc, args.url, args.timeout))
        return 1

    if status == 401:
        report_unauthorized(args.url)
        return 1
    if not 200 <= status < 300:
        print_error("initialize failed: " + http_error_text(status, body))
        return 1

    try:
        response = parse_response(body, get_content_type(headers), 1)
    except ValueError as exc:
        print_error("initialize failed: " + str(exc))
        return 1

    rpc_error = json_rpc_error_text(response)
    if rpc_error:
        print_error("initialize failed: " + rpc_error)
        return 1

    result = response.get("result")
    if not isinstance(result, dict):
        print_error("initialize failed: response has no result object.")
        return 1

    session_id = headers.get("Mcp-Session-Id") if headers is not None else None
    protocol_version = PROTOCOL_VERSION
    if isinstance(result.get("protocolVersion"), str):
        protocol_version = result["protocolVersion"]

    notification = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    try:
        status, headers, body = post_message(
            args.url,
            notification,
            token=token,
            timeout=args.timeout,
            session_id=session_id,
            protocol_version=protocol_version,
        )
    except Exception as exc:
        print_error(network_error_text(exc, args.url, args.timeout))
        return 1

    if status == 401:
        report_unauthorized(args.url)
        return 1
    if not 200 <= status < 300:
        print_error(
            "notifications/initialized failed: "
            + http_error_text(status, body)
        )
        return 1
    # The notification response has no useful body; ignore it.

    tools = []
    cursor = None
    request_id = 2
    seen_cursors = set()
    page_count = 0
    while True:
        tools_request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/list",
            "params": {"cursor": cursor} if cursor else {},
        }
        try:
            status, headers, body = post_message(
                args.url,
                tools_request,
                token=token,
                timeout=args.timeout,
                session_id=session_id,
                protocol_version=protocol_version,
            )
        except Exception as exc:
            print_error(network_error_text(exc, args.url, args.timeout))
            return 1

        if status == 401:
            report_unauthorized(args.url)
            return 1
        if not 200 <= status < 300:
            print_error("tools/list failed: " + http_error_text(status, body))
            return 1

        try:
            response = parse_response(
                body, get_content_type(headers), request_id
            )
        except ValueError as exc:
            print_error("tools/list failed: " + str(exc))
            return 1

        rpc_error = json_rpc_error_text(response)
        if rpc_error:
            print_error("tools/list failed: " + rpc_error)
            return 1

        result = response.get("result")
        if not isinstance(result, dict) or not isinstance(
            result.get("tools"), list
        ):
            print_error("tools/list failed: response has no result.tools array.")
            return 1

        page = result["tools"]
        tools.extend(page)
        cursor = result.get("nextCursor")
        if not cursor:
            break
        if cursor in seen_cursors:
            print_error("tools/list repeated cursor %r; aborting." % cursor)
            return 1
        seen_cursors.add(cursor)
        page_count += 1
        if page_count > 100:
            print_error("tools/list pagination exceeded 100 pages; aborting.")
            return 1
        request_id += 1
    names = [
        tool.get("name")
        for tool in tools
        if isinstance(tool, dict) and isinstance(tool.get("name"), str)
    ]
    present = set(names)
    missing_required = [name for name in required_tools if name not in present]
    exposed = [name for name in blocked_tools if name in present]

    if not args.quiet:
        print("Tool count: %d" % len(tools))
        preview = ", ".join(names[:8])
        if len(names) > 8:
            preview += ", ... (+%d more)" % (len(names) - 8)
        print("First tools: " + (preview or "(none)"))

    if missing_required:
        print_error(
            "required tools are missing: " + ", ".join(missing_required)
        )
        return 1

    if exposed:
        print_error("blocked tools are exposed: " + ", ".join(exposed))
        return 2

    if not args.quiet:
        if blocked_tools:
            print("blocked tools absent: " + ", ".join(blocked_tools))
        else:
            print("blocked tools absent: (none configured)")
    return 0


def main(argv=None):
    args = parse_args(argv)

    if args.expect_unauthorized:
        return check_unauthorized(args)

    token, token_error = resolve_token(args)
    if token_error:
        print_error(token_error)
        return 1
    if not token:
        print_error(
            "no bearer token available; normal mode requires one. Pass "
            "--token-file PATH (or --token TOKEN), or write the token to "
            "$XDG_CONFIG_HOME/freecad-ai/mcp-token."
        )
        return 1

    blocked_tools = parse_blocked_tools(args.blocked_tools)
    required_tools = parse_blocked_tools(args.required_tools)
    return check_server(args, token, blocked_tools, required_tools)


if __name__ == "__main__":
    sys.exit(main())
