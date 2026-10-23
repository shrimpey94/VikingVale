# CSG Sandbox — hand-build models in Godot (no extra software)

CSG = **Constructive Solid Geometry**: you combine simple shapes (box, sphere,
cylinder…) and add/subtract them to build a model, all in the editor with the mouse.
It's Godot's version of Unity's ProBuilder. Great for **buildings, props, walls,
furniture, simple monsters**. (For detailed characters, Blender later.)

## Open it
1. Launch the **Godot editor** (open the VikingVale project).
2. In the **FileSystem** panel (bottom-left), open `handmade/CSGSandbox.tscn`.
3. You'll see a little house (walls + pyramid roof + a doorway cut out) on a ground.
   Press **F6** to run it and see it lit; press **F8** / close to stop.

## Move around the 3D view
- **Middle-mouse drag** = orbit the camera.
- **Shift + middle-mouse** = pan.
- **Mouse wheel** = zoom.
- Press **F** with a node selected = focus/frame it.

## Add a shape
1. In the **Scene** panel (top-left), click the **`MyBuilding`** node (the CSGCombiner).
2. Click the **`+`** (Add Child Node), search **CSG**, and pick one:
   - **CSGBox3D** — a box (walls, floors, crates, roofs).
   - **CSGCylinder3D** — a cylinder; check **Cone** in the Inspector for a pyramid/spike; set **Sides** low (4–6) for a chunky look.
   - **CSGSphere3D** — a ball (heads, boulders, domes).
   - **CSGTorus3D** — a ring.
3. It appears at the center. Keep new shapes **under `MyBuilding`** so they combine.

## Move / rotate / scale (like Unity)
With a shape selected, use the toolbar gizmo buttons (top of the viewport) or keys:
- **W** = Move (drag the red/green/blue arrows for X/Y/Z).
- **E** = Rotate (drag the rings).
- **R** = Scale (drag the handles).
- Or type exact numbers in the **Inspector** (right panel): `Transform > Position`,
  and each CSG shape's own **Size / Radius / Height**.

## Combine — the magic part
Select a shape and in the **Inspector** set **`Operation`**:
- **Union** (default) = adds it to the model.
- **Subtraction** = **carves it out** (that's how the doorway is cut — see `DoorCut`).
- **Intersection** = keeps only the overlap.
Order matters top-to-bottom in the Scene panel: shapes combine down the list.

## Color it
1. Select a shape → Inspector → **`Material`** → **New StandardMaterial3D**.
2. Click the material → set **Albedo > Color**.
(Or reuse one: drag an existing material onto another shape's Material slot.)

## Tips for our low-poly style
- Keep **Sides low** (4–8) on cylinders/spheres so it matches the game's chunky look.
- Build the **silhouette first** (big boxes), then add detail (small boxes/cones).
- Duplicate with **Ctrl+D** to repeat parts (windows, pillars, spikes).

## When you've built something
- **Save** the scene (Ctrl+S). Tell me the node/scene name (e.g. "the tavern in
  CSGSandbox") and **I'll wire it into the game** to replace a procedural model —
  e.g. your building becomes the real Tavern, your prop becomes a placeable, etc.
- You can make several models in this one scene (put each under its own
  CSGCombiner3D) — just name them so I know which is which.

## Later: Blender (for characters / detailed models)
When you're ready: model in **Blender** (free), **File > Export > glTF (.glb)**, drop
the `.glb` into the project's `handmade/` folder — Godot auto-imports it and I hook
it in. Same pipeline pro Godot **and** Unity teams use. No rush; CSG covers a lot.
