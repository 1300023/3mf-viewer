#!/usr/bin/env python3
"""Generates a small library of colourful demo .3mf files (used for the README screenshots).

    pip install numpy trimesh shapely
    python3 scripts/make_demo_models.py ~/Desktop/3mf-demo

The files use the same layout as Bambu Studio / OrcaSlicer projects: filament colours in
Metadata/project_settings.config, per-object and per-part extruders in Metadata/model_settings.config,
plus 3MF colour groups — so they exercise every colour feature of the viewer.
"""
import json
import math
import os
import sys
import zipfile

import numpy as np
import trimesh
from shapely.geometry import Point, Polygon

rng = np.random.default_rng(7)


# ----------------------------------------------------------------------------- helpers

def grid_surface(points):
    """points: (rows, cols, 3) ring grid (cols wrap around) → faces of the side wall."""
    rows, cols, _ = points.shape
    faces = []
    for r in range(rows - 1):
        for c in range(cols):
            a = r * cols + c
            b = r * cols + (c + 1) % cols
            d = (r + 1) * cols + c
            e = (r + 1) * cols + (c + 1) % cols
            faces += [(a, b, e), (a, e, d)]
    return points.reshape(-1, 3), np.array(faces)


def cap(ring_start, count, center_index, flip):
    faces = []
    for c in range(count):
        a, b = ring_start + c, ring_start + (c + 1) % count
        faces.append((center_index, b, a) if not flip else (center_index, a, b))
    return faces


def closed_ring_solid(rings):
    """rings: (rows, cols, 3) profile rings from bottom to top → watertight solid with flat caps."""
    verts, faces = grid_surface(rings)
    rows, cols, _ = rings.shape
    bottom_center = len(verts)
    top_center = bottom_center + 1
    centers = np.array([rings[0].mean(axis=0), rings[-1].mean(axis=0)])
    verts = np.vstack([verts, centers])
    faces = list(map(tuple, faces))
    faces += cap(0, cols, bottom_center, flip=False)
    faces += cap((rows - 1) * cols, cols, top_center, flip=True)
    mesh = trimesh.Trimesh(verts, np.array(faces), process=True)
    mesh.fix_normals()
    return mesh


def shell(outer, inner):
    """Hollow vessel: outer rings, inner rings (same shape), open top joined by a rim, solid bottom."""
    rows, cols, _ = outer.shape
    ov, of = grid_surface(outer)
    iv, inf = grid_surface(inner)
    verts = np.vstack([ov, iv])
    n = len(ov)
    faces = list(map(tuple, of)) + [tuple(f[::-1] + n) for f in inf]
    # top rim
    top_o, top_i = (rows - 1) * cols, n + (rows - 1) * cols
    for c in range(cols):
        a, b = top_o + c, top_o + (c + 1) % cols
        d, e = top_i + c, top_i + (c + 1) % cols
        faces += [(a, e, b), (a, d, e)]
    # bottom: outer bottom cap and inner floor cap
    centers = np.array([outer[0].mean(axis=0), inner[0].mean(axis=0)])
    verts = np.vstack([verts, centers])
    faces += cap(0, cols, len(verts) - 2, flip=False)
    faces += cap(n, cols, len(verts) - 1, flip=True)
    mesh = trimesh.Trimesh(verts, np.array(faces), process=True)
    return mesh


def revolve(profile, sections=96):
    """profile: list of (radius, z) from bottom axis to top axis."""
    return trimesh.creation.revolve(np.array(profile, dtype=float), sections=sections)


def on_plate(mesh):
    mesh = mesh.copy()
    mesh.apply_translation([0, 0, -mesh.bounds[0][2]])
    return mesh


# ----------------------------------------------------------------------------- models

def twisted_vase():
    layers, segs = 150, 120
    rings = np.zeros((layers, segs, 3))
    for i in range(layers):
        z = 140 * i / (layers - 1)
        base_r = 34 + 12 * math.sin(math.pi * z / 140 * 1.2) - 6 * (z / 140) ** 2
        twist = math.radians(110) * z / 140
        for j in range(segs):
            t = 2 * math.pi * j / segs
            r = base_r * (1 + 0.10 * math.cos(9 * (t + twist)))
            rings[i, j] = (r * math.cos(t), r * math.sin(t), z)
    inner = rings.copy()
    for i in range(layers):
        center = np.array([0, 0, rings[i, 0, 2]])
        inner[i] = center + (rings[i] - center) * 0.93
        inner[i, :, 2] = max(rings[i, 0, 2], 2.0)
    return on_plate(shell(rings, inner))


def torus_knot(p=2, q=3):
    n, m = 600, 36
    t = np.linspace(0, 2 * np.pi, n, endpoint=False)
    R, r, tube = 32, 13, 7.5
    curve = np.stack([(R + r * np.cos(q * t)) * np.cos(p * t),
                      (R + r * np.cos(q * t)) * np.sin(p * t),
                      r * np.sin(q * t)], axis=1)
    tangent = np.roll(curve, -1, axis=0) - np.roll(curve, 1, axis=0)
    tangent /= np.linalg.norm(tangent, axis=1)[:, None]
    normal = np.cross(tangent, [0, 0, 1])
    normal /= np.linalg.norm(normal, axis=1)[:, None]
    binormal = np.cross(tangent, normal)
    verts = []
    for i in range(n):
        for j in range(m):
            a = 2 * np.pi * j / m
            verts.append(curve[i] + tube * (np.cos(a) * normal[i] + np.sin(a) * binormal[i]))
    faces = []
    for i in range(n):
        for j in range(m):
            a = i * m + j
            b = i * m + (j + 1) % m
            c = ((i + 1) % n) * m + j
            d = ((i + 1) % n) * m + (j + 1) % m
            faces += [(a, c, d), (a, d, b)]
    mesh = trimesh.Trimesh(np.array(verts), np.array(faces))
    mesh.fix_normals()
    return on_plate(mesh)


def gear(teeth, module_, thickness, hole):
    pitch_r = teeth * module_ / 2
    outer_r, root_r = pitch_r + module_, pitch_r - 1.25 * module_
    pts = []
    for k in range(teeth):
        base = 2 * math.pi * k / teeth
        step = 2 * math.pi / teeth
        for frac, rad in [(0.00, root_r), (0.18, root_r), (0.30, outer_r), (0.52, outer_r), (0.64, root_r), (1.0, root_r)]:
            a = base + frac * step
            pts.append((rad * math.cos(a), rad * math.sin(a)))
    poly = Polygon(pts).buffer(0.3).buffer(-0.3)
    poly = poly.difference(Point(0, 0).buffer(hole, 48))
    # Lightening holes for bigger gears.
    if teeth >= 30:
        for k in range(6):
            a = 2 * math.pi * k / 6
            c = ((root_r + hole) / 2 * math.cos(a), (root_r + hole) / 2 * math.sin(a))
            poly = poly.difference(Point(c).buffer((root_r - hole) * 0.28, 40))
    return trimesh.creation.extrude_polygon(poly, thickness)


def rocket_parts():
    body = revolve([(0, 0), (15, 0), (15, 70), (0, 70)], 96)
    body.apply_translation([0, 0, 16])
    nose_profile = [(15 * math.cos(math.pi / 2 * i / 24) ** 0.8, 86 + 42 * math.sin(math.pi / 2 * i / 24)) for i in range(25)]
    nose = revolve([(0, 86)] + nose_profile[:-1] + [(0, 128)], 96)
    nozzle = revolve([(0, 4), (9, 4), (12, 0), (12.8, 0), (11, 16), (0, 16)], 64)
    fins = []
    for k in range(3):
        fin = trimesh.creation.extrude_polygon(Polygon([(13, 0), (36, 0), (36, 8), (13, 46)]), 3)
        fin.apply_translation([0, 0, -1.5])
        rot = trimesh.transformations.rotation_matrix(math.pi / 2, [1, 0, 0])
        fin.apply_transform(rot)
        fin.apply_transform(trimesh.transformations.rotation_matrix(2 * math.pi * k / 3, [0, 0, 1]))
        fin.apply_translation([0, 0, 2])
        fins.append(fin)
    fins = trimesh.util.concatenate(fins)
    window = trimesh.creation.cylinder(radius=7, height=4, sections=64)
    window.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 1, 0]))
    window.apply_translation([14.6, 0, 66])
    ring = trimesh.creation.annulus(r_min=7, r_max=9, height=3, sections=64)
    ring.apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 1, 0]))
    ring.apply_translation([14.9, 0, 66])
    return [("Body", body, 1), ("Nose cone", nose, 2), ("Fins", fins, 2), ("Window", window, 3),
            ("Window ring", ring, 4), ("Nozzle", nozzle, 4)]


def terrain():
    n = 120
    size = 120.0
    xs = np.linspace(-size / 2, size / 2, n)
    X, Y = np.meshgrid(xs, xs)
    H = np.zeros_like(X)
    for octave in range(6):
        f = 0.018 * 2 ** octave
        amp = 22 / 1.9 ** octave
        phase = rng.uniform(0, 2 * np.pi, 4)
        H += amp * (np.sin(f * X + phase[0]) * np.cos(f * Y + phase[1]) + 0.6 * np.sin(f * (X + Y) * 0.7 + phase[2]))
    H += 18 * np.exp(-((X - 12) ** 2 + (Y + 8) ** 2) / 700)
    H = H - H.min()
    water = np.percentile(H, 22)
    H = np.maximum(H, water) + 6

    verts = np.stack([X.ravel(), Y.ravel(), H.ravel()], axis=1)
    faces = []
    for i in range(n - 1):
        for j in range(n - 1):
            a = i * n + j
            faces += [(a, a + 1, a + n + 1), (a, a + n + 1, a + n)]
    top_count = len(faces)
    # skirt + bottom
    border = [i for i in range(n)] + [i * n + n - 1 for i in range(1, n)] + \
             [n * n - 1 - i for i in range(1, n)] + [(n - 1 - i) * n for i in range(1, n - 1)]
    base_start = len(verts)
    base = verts[border].copy()
    base[:, 2] = 0
    verts = np.vstack([verts, base])
    m = len(border)
    for k in range(m):
        a, b = border[k], border[(k + 1) % m]
        c, d = base_start + k, base_start + (k + 1) % m
        faces += [(a, c, d), (a, d, b)]
    center = len(verts)
    verts = np.vstack([verts, [[0, 0, 0]]])
    for k in range(m):
        faces.append((center, base_start + (k + 1) % m, base_start + k))
    faces = np.array(faces)

    # Colour bands by height.
    zc = verts[faces[:top_count]].mean(axis=1)[:, 2]
    hmax = H.max()
    bands = []
    for z in zc:
        if z <= water + 6.05:
            bands.append(0)
        elif z < water + 8.5:
            bands.append(1)
        elif z < hmax * 0.62:
            bands.append(2)
        elif z < hmax * 0.78:
            bands.append(3)
        elif z < hmax * 0.9:
            bands.append(4)
        else:
            bands.append(5)
    bands += [6] * (len(faces) - top_count)
    colors = ["#2E86DE", "#E8D8A0", "#6AB04C", "#3B7A3B", "#8D7B6A", "#FAFAFA", "#5D4E3F"]
    return verts, faces, bands, colors


def chess_pieces():
    pawn = revolve([(0, 0), (14, 0), (14, 3), (11, 5), (9, 8), (6, 20), (9, 22), (9, 24), (5, 26),
                    (7.5, 30), (8, 33), (7, 37), (4, 39.5), (0, 40)], 72)
    rook = revolve([(0, 0), (15, 0), (15, 3), (12, 6), (10, 10), (9, 32), (12, 34), (12, 44), (0, 44)], 72)
    notch = [trimesh.creation.box(extents=[30, 4.5, 6]) for _ in range(2)]
    notch[0].apply_translation([0, 0, 42])
    notch[1].apply_transform(trimesh.transformations.rotation_matrix(math.pi / 2, [0, 0, 1]))
    notch[1].apply_translation([0, 0, 42])
    try:
        rook = rook.difference(trimesh.util.concatenate(notch))
    except BaseException:
        pass
    bishop = revolve([(0, 0), (14, 0), (14, 3), (11, 5), (8, 9), (5.5, 30), (9, 32), (9, 34), (5, 36),
                      (7, 42), (6.5, 48), (3.5, 53), (2, 54), (3, 56), (0, 58)], 72)
    king = revolve([(0, 0), (16, 0), (16, 3), (12, 6), (9, 11), (6.5, 38), (11, 41), (11, 43), (6, 45),
                    (9, 52), (8, 58), (4, 61), (0, 61)], 72)
    cross_v = trimesh.creation.box(extents=[3.5, 3.5, 14])
    cross_v.apply_translation([0, 0, 67])
    cross_h = trimesh.creation.box(extents=[11, 3.5, 3.5])
    cross_h.apply_translation([0, 0, 68])
    king = trimesh.util.concatenate([king, cross_v, cross_h])
    return {"Pawn": pawn, "Rook": rook, "Bishop": bishop, "King": king}


def wave_lamp():
    layers, segs = 140, 160
    outer = np.zeros((layers, segs, 3))
    for i in range(layers):
        z = 110 * i / (layers - 1)
        base_r = 42 - 10 * (z / 110) ** 1.5
        for j in range(segs):
            t = 2 * math.pi * j / segs
            r = base_r + 3.2 * math.sin(14 * t + z / 7.0) + 1.2 * math.sin(5 * t - z / 13)
            outer[i, j] = (r * math.cos(t), r * math.sin(t), z)
    inner = outer.copy()
    for i in range(layers):
        center = np.array([0, 0, outer[i, 0, 2]])
        inner[i] = center + (outer[i] - center) * 0.94
        inner[i, :, 2] = max(outer[i, 0, 2], 1.6)
    return on_plate(shell(outer, inner))


def lowpoly_planter():
    rings_z = [0, 14, 30, 48, 62]
    radii = [26, 34, 40, 41, 38]
    segs = 9
    outer = np.zeros((len(rings_z), segs, 3))
    for i, (z, r) in enumerate(zip(rings_z, radii)):
        for j in range(segs):
            t = 2 * math.pi * (j + 0.5 * (i % 2)) / segs
            rr = r * (1 + rng.uniform(-0.05, 0.05))
            outer[i, j] = (rr * math.cos(t), rr * math.sin(t), z)
    inner = outer.copy()
    for i in range(len(rings_z)):
        inner[i, :, :2] *= 0.85
        inner[i, :, 2] = max(rings_z[i], 4)
    return on_plate(shell(outer, inner))


# ----------------------------------------------------------------------------- 3MF writer

class Project:
    def __init__(self, title, filaments):
        self.title = title
        self.filaments = filaments
        self.objects = []  # (id, xml)
        self.items = []  # (object id, x, y)
        self.settings = []  # model_settings object xml
        self.colorgroups = []
        self.next_id = 1

    def _id(self):
        i = self.next_id
        self.next_id += 1
        return i

    @staticmethod
    def _mesh_xml(mesh, tri_attrs=None):
        v = "\n".join(f'<vertex x="{x:.3f}" y="{y:.3f}" z="{z:.3f}"/>' for x, y, z in mesh.vertices)
        t = []
        for k, (a, b, c) in enumerate(mesh.faces):
            extra = tri_attrs[k] if tri_attrs else ""
            t.append(f'<triangle v1="{a}" v2="{b}" v3="{c}"{extra}/>')
        return f"<mesh><vertices>\n{v}\n</vertices><triangles>\n" + "\n".join(t) + "\n</triangles></mesh>"

    def add_colorgroup(self, colors):
        gid = self._id()
        body = "".join(f'<m:color color="{c}"/>' for c in colors)
        self.colorgroups.append(f'<m:colorgroup id="{gid}">{body}</m:colorgroup>')
        return gid

    def add_object(self, name, mesh, extruder, x, y, tri_attrs=None):
        oid = self._id()
        self.objects.append(f'<object id="{oid}" name="{name}" type="model">{self._mesh_xml(mesh, tri_attrs)}</object>')
        self.items.append((oid, x, y))
        self.settings.append(f'<object id="{oid}"><metadata key="name" value="{name}"/>'
                             f'<metadata key="extruder" value="{extruder}"/></object>')
        return oid

    def add_assembly(self, name, parts, x, y):
        """parts: [(part name, mesh, extruder)] → one object made of components (like a Bambu multi-part object)."""
        part_ids = []
        part_settings = []
        for part_name, mesh, extruder in parts:
            pid = self._id()
            self.objects.append(f'<object id="{pid}" type="model">{self._mesh_xml(mesh)}</object>')
            part_ids.append(pid)
            part_settings.append(f'<part id="{pid}" subtype="normal_part"><metadata key="name" value="{part_name}"/>'
                                 f'<metadata key="extruder" value="{extruder}"/></part>')
        oid = self._id()
        comps = "".join(f'<component objectid="{pid}"/>' for pid in part_ids)
        self.objects.append(f'<object id="{oid}" name="{name}" type="model"><components>{comps}</components></object>')
        self.items.append((oid, x, y))
        self.settings.append(f'<object id="{oid}"><metadata key="name" value="{name}"/>'
                             f'<metadata key="extruder" value="1"/>' + "".join(part_settings) + "</object>")

    def save(self, path, description):
        meta = {
            "Title": self.title,
            "Designer": "3MF Viewer",
            "Description": description,
            "Application": "3MF Viewer demo generator",
            "License": "CC0 1.0",
            "CreationDate": "2026-09-23",
        }
        meta_xml = "\n".join(f' <metadata name="{k}">{v}</metadata>' for k, v in meta.items())
        items = "\n".join(f'  <item objectid="{oid}" transform="1 0 0 0 1 0 0 0 1 {x:.2f} {y:.2f} 0" printable="1"/>'
                          for oid, x, y in self.items)
        model = f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
       xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02">
{meta_xml}
 <resources>
{''.join(self.colorgroups)}
{''.join(self.objects)}
 </resources>
 <build>
{items}
 </build>
</model>"""
        rels = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>"""
        types = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="config" ContentType="text/xml"/>
</Types>"""
        settings = '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n' + "\n".join(self.settings) + "\n</config>"
        project = json.dumps({"filament_colour": self.filaments}, indent=1)
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("[Content_Types].xml", types)
            z.writestr("_rels/.rels", rels)
            z.writestr("3D/3dmodel.model", model)
            z.writestr("Metadata/model_settings.config", settings)
            z.writestr("Metadata/project_settings.config", project)
        print(f"  {os.path.basename(path):28s} {os.path.getsize(path) / 1024:8.0f} KB")


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    cx = cy = 128

    p = Project("Twisted Vase", ["#1FB5A8"])
    p.add_object("Twisted vase", twisted_vase(), 1, cx, cy)
    p.save(os.path.join(out_dir, "Twisted Vase.3mf"), "Spiral vase with a nine-lobe twisted profile.")

    p = Project("Trefoil Knot", ["#D6336C"])
    p.add_object("Trefoil knot", torus_knot(), 1, cx, cy)
    p.save(os.path.join(out_dir, "Trefoil Knot.3mf"), "A (2,3) torus knot swept with a round tube.")

    p = Project("Gear Train", ["#F57C00", "#ECEFF1", "#455A64"])
    p.add_object("Large gear", gear(36, 2.0, 8, 5), 1, cx - 30, cy)
    p.add_object("Medium gear", gear(20, 2.0, 8, 4), 2, cx + 27.5, cy + 6)
    p.add_object("Small gear", gear(12, 2.0, 12, 3), 3, cx + 12, cy - 36)
    p.save(os.path.join(out_dir, "Gear Train.3mf"), "Three meshing spur gears in three filaments.")

    p = Project("Retro Rocket", ["#F5F5F5", "#E53935", "#29B6F6", "#546E7A"])
    p.add_assembly("Retro rocket", rocket_parts(), cx, cy)
    p.save(os.path.join(out_dir, "Retro Rocket.3mf"), "Multi-part rocket: every part has its own filament.")

    verts, faces, bands, colors = terrain()
    p = Project("Island Terrain", [])
    gid = p.add_colorgroup(colors)
    mesh = trimesh.Trimesh(verts, faces, process=False)
    p.add_object("Island", mesh, 1, cx, cy, tri_attrs=[f' pid="{gid}" p1="{b}"' for b in bands])
    p.save(os.path.join(out_dir, "Island Terrain.3mf"), "Height-map terrain coloured with a 3MF colour group.")

    pieces = chess_pieces()
    p = Project("Chess Pieces", ["#EFE6D2", "#2F2F33"])
    order = ["Rook", "Bishop", "King", "Pawn"]
    for row, extruder in [(0, 1), (1, 2)]:
        for col, name in enumerate(order):
            p.add_object(f"{name} ({'white' if extruder == 1 else 'black'})", pieces[name], extruder,
                         cx - 57 + col * 38, cy - 20 + row * 40)
    p.save(os.path.join(out_dir, "Chess Pieces.3mf"), "Lathe-turned chess pieces in two colours.")

    p = Project("Wave Lamp Shade", ["#FFC83D"])
    p.add_object("Lamp shade", wave_lamp(), 1, cx, cy)
    p.save(os.path.join(out_dir, "Wave Lamp Shade.3mf"), "Rippled lamp shade, printable in vase mode.")

    p = Project("Low-poly Planter", ["#7CB342"])
    p.add_object("Planter", lowpoly_planter(), 1, cx, cy)
    p.save(os.path.join(out_dir, "Low-poly Planter.3mf"), "Faceted planter.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "demo-models")
