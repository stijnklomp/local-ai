# FreeCAD project

FreeCAD 1.1.3 runs on the host with the FreeCAD AI workbench, and the `freecad` MCP server is attached to this sandbox. Use those tools for all modelling work in this directory.

## Start here

- The MCP server can only work on documents already open in FreeCAD. Ask the user to open the `.FCStd` file first; there is no open-file tool.
- Inspect `list_documents`, then call `get_document_state` on the active document before making changes.
- Confirm the goal and key dimensions first. Work in millimetres.

## Modelling rules

- Prefer structured tools over code: `create_primitive`, `create_sketch`, `pad_sketch`, `pocket_sketch`, `boolean_operation`, `fillet_edges`, and related tools.
- Keep the feature tree simple and ordered: sketches before pads and pockets, booleans after solids, fillets last.
- The MCP toolset has no save tool. Ask the user to save the `.FCStd` in FreeCAD (Ctrl+S) before and after significant changes. Use `export_model` to write STL/STEP into the current project directory; ask before overwriting files.
- Ask the user to save often. FreeCAD AI is alpha and a tool call can fail partway through an operation.

## Safety

- The host MCP server serves only an explicit allowlist of structured modeling tools. Code execution, skills, user extension tools and macros-as-tools are not available.
- `export_model` and `capture_viewport` refuse paths outside this project directory.
- Do not include secrets in prompts, file names, or exports. Refer to files relative to the project directory.

## Explain the work

After each meaningful change, explain briefly to a FreeCAD beginner what changed and how it affects the feature tree, for example: "Padding Sketch001 creates Pad, which consumes the sketch and adds the solid."
