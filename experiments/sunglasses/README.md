# Portrait › Sunglasses trial (2026-10-13)

Offline trial behind the approved design `docs/ui/proposals/portrait-sunglasses-v2.html`. Results:
`docs/ui/proposals/sunglasses-*.png|jpg`. Python 3.11 with ai-edge-litert, numpy, pillow; Swift scripts compile
with `swiftc -O` on macOS. Every script takes a work directory `S` (models, landmarks and renders are written there).

Pipeline, in order:

| Step | Script | Notes |
|---|---|---|
| Face boxes and eye points | (Apple Vision, `pose.swift` in the work dir) | Only a starting crop for the landmarker |
| 478 landmarks | `landmarks3.py` | MediaPipe `face_landmarks_detector.tflite`; tries 7 crop rotations, then re-crops twice along forehead–chin. Keeps the face-presence logit; below 0 the face is skipped |
| Hair, background, accessories | `hair.py` | `selfie_multiclass_256x256.tflite`: wide crop (3.6× face) for hair and outline, tight crop (1.4×) for thin glasses rims |
| Models | `fbxtex.py`, `objinfo.py`, `normalize.py` | The 10 purchased pairs (in `~/Downloads/Sunglasses 3D`, not in git) to metres, x across, y up, z forward, origin at the lens centre; lens parts found automatically; arms splayed to 80 mm |
| Render | `render_glasses3.swift` | SceneKit, orthographic, three passes (frame, front 1.2 cm, lens coverage); invisible head ellipsoid and the photo's face mesh hide what is behind the face |
| Compose | `wear.py` | Paints out existing glasses (LaMa), places the pair 15 mm in front of the irises along the head's axis, corrects profile yaw from the far eye's distance to the outline, tints the photo through the lenses, contact shadow, hair over the arms |
| Sheets | `grid.py`, `models_faces.sh` | All models on six faces |

`canonical_face.npy` and `facemesh_tris.npy` are MediaPipe's canonical face (468 vertices, cm) and its 898
triangles, read from the landmarker bundle's `geometry_pipeline_metadata_landmarks.binarypb`.
`render_glasses2.swift` is the earlier single-model renderer (Ray-Ban RB4195 only).

Owner decisions: replace existing glasses rather than tint them; profiles supported; LV pairs dropped; all ten
remaining pairs ship in 1.1; arms must reach the ear, never cut off.
