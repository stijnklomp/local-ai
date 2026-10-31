# FreeCAD project

FreeCAD 1.1.3 runs on the host with the FreeCAD AI workbench, and the `freecad` MCP server is attached to this sandbox. Use those tools for all modelling work in this directory. Work in millimetres.

## Start here

- The MCP server can only work on documents already open in FreeCAD. Ask the user to open the `.FCStd` file first; there is no open-file tool.
- Inspect `list_documents`, then call `get_document_state` on the active document before making changes.
- Confirm the goal and the key dimensions first. Ask for the numbers you do not have rather than guessing them.
- Re-read `get_document_state` after the user saves. They save under new file names and undo state resets; a boolean made earlier in the session can silently disappear.
- Get exact signatures with `search({query: "<tool>", namespace: "mcp-gateway"})` before calling an unfamiliar tool. Argument names are easy to guess wrong (`set_view` takes `orientation`, not `view`).

## Orient yourself before cutting anything

Words like "above", "left", "bottom" and "the other one" are unreliable. A viewer is often looking at the part from a side that does not match the model axes — a 180° rotation is common — and a wrong feature costs a full rebuild.

- Turn every positional request into a measured one. "The small compartment above it" becomes "the 46 × 31.6 pocket at X −81.75…−35.75".
- Restate the target and its dimensions in your reply before modelling, so the user can correct you cheaply.
- When two candidates are close in size, ask which one rather than picking.

## Measure what already exists

- Never infer a boundary from a face centre. Fillets and chamfers truncate flat faces, so the shortest visible end reads as "the wall" and silently shortens whatever you add.
- Derive boundaries from geometry: `section_object` plus `list_edges` on the section gives exact wall coordinates; `measure` gives distances between features.
- Do not assume symmetry. Measure both sides if symmetry matters; they are often not equal.
- Treat an imported or generated part (no feature tree) as given geometry: inspect the surfaces where your shape will land, including fillets, chamfers and draft.

## Joining new geometry to existing geometry

- Overlap slightly (roughly 0.3–0.5 mm) into the host solid instead of sitting flush against it. Flush faces invite hairline gaps and boolean slivers; a small overlap is invisible and robust.
- Check the junction surface first. A base fillet means the wall is not where the flat face says; a feature that bottoms out below the fillet's top edge leaves the fillet exposed as a visible sliver.
- Extend seams into every wall the feature meets, not just the ones that are easy to see.
- Distinguish intentional clearance from a defect. Before closing a "gap", identify which of these it is: modelled clearance, a boolean sliver or degenerate face, an exposed host fillet, or a real hole. Only the last one matters structurally; the rest are cosmetic — say so.

## Design for printing

Ask for the printer's nozzle/line width and wall count when fit matters; do not assume.

- No knife edges. Round ridges, rims and creases that will be touched or loaded — a small fillet is enough.
- Avoid features thinner than roughly one extrusion width; they print as gaps or artefacts.
- Keep overhang angles in mind. Upward-facing slopes are free; sharp undercuts need support.
- Tightening features (V grooves, slots, clips) need real clearance, not nominal zero. Size against the part that goes in it.
- Infill percentage does not affect surface features — walls and top/bottom skins do. Do not "improve" a thin surface by raising infill.

## Tool behaviour that will bite

| Symptom | What is really happening |
| --- | --- |
| `create_sketch` reports 0 geometries | `type:"polygon"` is silently ignored. Build outlines from individual `line` / `arc` entries. |
| Sketch lands somewhere unexpected | `offset` is unreliable. Create at offset 0, then `transform_object` the Body and confirm the bbox with `describe_model`. |
| `modify_property(..., "Length")` on a `PartDesign::Pad` reports success but nothing changes | It does not stick. Delete the pad and re-create it with `pad_sketch`. |
| Object "not found" after renaming | Lookup resolves internal name first, then label. Never give an object another object's internal name as a label, and prefer leaving names alone. |
| `delete_object` refuses | Something still links to it. Delete the dependent first — e.g. the final `Part::Fuse`, then the body it consumed. |
| `section_object` returns 0 edges | It fails on `Part::Fuse`. Section a plain `Part::Feature` instead. |
| `list_edges` errors on a partially valid shape | Fall back to `list_faces`, or section the object and list the section's edges. |
| `capture_viewport` shows the previous view, or a blank scene | Camera changes land one frame late — capture twice. Booleans auto-hide their sources; set `Visibility` back to `True` before capturing. |
| Rounding a ridge | Prefer `fillet_edges` on the pad over arcs in the sketch: it adds a `PartDesign::Fillet` feature inside the body, and downstream fuses recompute. |

## Modelling rules

- Prefer structured tools over code: `create_primitive`, `create_sketch`, `pad_sketch`, `pocket_sketch`, `boolean_operation`, `fillet_edges`, and related tools.
- Keep the feature tree simple and ordered: sketches before pads and pockets, booleans after solids, fillets last.
- Fuse added bodies into the host with `boolean_operation(operation:"fuse")`. The result is a new object and the sources stay in the tree — keep them hidden, not deleted; a `Part::Fuse` still links to them.
- The MCP toolset has no save tool. Ask the user to save (Ctrl+S) before and after significant changes. FreeCAD AI is alpha and a call can fail partway.
- Some designs here are produced by an external generator, so the `.FCStd` may be regenerated from scratch. State the parameters you used in your reply so the change can be rebuilt.

## Verify every change

1. `describe_model` on the result: expect `Solids: 1`, `Valid: True`, and a volume delta that matches the added geometry. `Solids:` greater than one means the new body never merged.
2. Check the junctions you claim are closed: list faces and look for small stray faces, exposed fillets or degenerate slivers along them.
3. Prove a claim with a probe rather than an impression: temp `create_primitive` box → `boolean_operation(operation:"common")` → `describe_model` volume. Compare opposite sides of the same feature; they should match within ~1 %.
4. Delete temp bodies and probe objects, then confirm `get_document_state` before reporting.

## Safety

- The host MCP server serves only an explicit allowlist of structured modeling tools. Code execution, skills, user extension tools and macros-as-tools are not available.
- `export_model` and `capture_viewport` refuse paths outside this project directory.
- Do not include secrets in prompts, file names, or exports. Refer to files relative to the project directory.
- Never delete a source solid while a boolean or feature still references it.

## Explain the work

After each meaningful change, explain briefly to a FreeCAD beginner what changed and how it affects the feature tree, for example: "Padding Sketch001 creates Pad, which consumes the sketch and adds the solid."
