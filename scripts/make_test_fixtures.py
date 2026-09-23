#!/usr/bin/env python3
"""Generates the small .3mf files used by the unit tests (Tests/ThreeMFKitTests/Fixtures)."""
import io
import json
import os
import struct
import zipfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Tests", "ThreeMFKitTests", "Fixtures")

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
 <Default Extension="png" ContentType="image/png"/>
</Types>"""

RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
 <Relationship Target="/{thumb}" Id="rel1" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>
</Relationships>"""


def png(width=4, height=4, rgb=(255, 128, 0)):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def cube(size=1.0, offset=(0.0, 0.0, 0.0)):
    ox, oy, oz = offset
    s = size
    verts = [(ox + x * s, oy + y * s, oz + z * s) for z in (0, 1) for y in (0, 1) for x in (0, 1)]
    tris = [(0, 2, 1), (1, 2, 3), (4, 5, 6), (5, 7, 6), (0, 1, 4), (1, 5, 4),
            (2, 6, 3), (3, 6, 7), (0, 4, 2), (2, 4, 6), (1, 3, 5), (3, 7, 5)]
    return verts, tris


def vertices_xml(verts):
    return "\n".join(f'     <vertex x="{x:g}" y="{y:g}" z="{z:g}"/>' for x, y, z in verts)


def triangles_xml(tris, extra=None):
    extra = extra or {}
    rows = []
    for i, (a, b, c) in enumerate(tris):
        attrs = extra.get(i, "")
        rows.append(f'     <triangle v1="{a}" v2="{b}" v3="{c}"{attrs}/>')
    return "\n".join(rows)


def write(name, files, stored=()):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with zipfile.ZipFile(path, "w") as z:
        for arcname, data in files.items():
            method = zipfile.ZIP_STORED if arcname in stored else zipfile.ZIP_DEFLATED
            z.writestr(arcname, data, compress_type=method)
    print("written", path)


def make_cube():
    verts, tris = cube(1.0)
    model = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- A one-inch red cube -->
<model unit="inch" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
 <metadata name="Title">Test Cube</metadata>
 <metadata name="Designer">A &amp; B</metadata>
 <resources>
  <basematerials id="1">
   <base name="Red PLA" displaycolor="#FF0000"/>
   <base name="Blue PLA" displaycolor="#0000FFFF"/>
  </basematerials>
  <object id="3" type="model" pid="1" pindex="0" name="Cube">
   <mesh>
    <vertices>
{vertices_xml(verts)}
    </vertices>
    <triangles>
{triangles_xml(tris, {0: ' pid="1" p1="1"'})}
    </triangles>
   </mesh>
  </object>
 </resources>
 <build>
  <item objectid="3" transform="1 0 0 0 1 0 0 0 1 4 5 0"/>
 </build>
</model>"""
    write("cube.3mf", {
        "[Content_Types].xml": CONTENT_TYPES,
        "_rels/.rels": RELS.format(thumb="Metadata/thumbnail.png"),
        "3D/3dmodel.model": model,
        "Metadata/thumbnail.png": png(),
    })


def make_bambu():
    body_v, body_t = cube(20.0)
    mod_v, mod_t = cube(5.0, (5, 5, 5))
    painted = {0: ' paint_color="8"', 1: ' paint_color="8"', 2: ' paint_color="0C"'}
    objects = f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
       xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
 <resources>
  <object id="1" p:UUID="00010000-81cb-4c03-9d28-80fed5dfa1dc" type="model">
   <mesh>
    <vertices>
{vertices_xml(body_v)}
    </vertices>
    <triangles>
{triangles_xml(body_t, painted)}
    </triangles>
   </mesh>
  </object>
  <object id="3" p:UUID="00030000-81cb-4c03-9d28-80fed5dfa1dc" type="model">
   <mesh>
    <vertices>
{vertices_xml(mod_v)}
    </vertices>
    <triangles>
{triangles_xml(mod_t)}
    </triangles>
   </mesh>
  </object>
 </resources>
 <build/>
</model>"""
    root = """<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
       xmlns:BambuStudio="http://schemas.bambulab.com/package/2021"
       xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
 <metadata name="Application">BambuStudio-01.09.00.70</metadata>
 <metadata name="BambuStudio:3mfVersion">1</metadata>
 <resources>
  <object id="2" p:UUID="00000001-61cb-4c03-9d28-80fed5dfa1dc" type="model">
   <components>
    <component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
    <component p:path="/3D/Objects/object_1.model" objectid="3" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
   </components>
  </object>
 </resources>
 <build p:UUID="2c7c17d8-22b5-4d84-8835-1976022ea369">
  <item objectid="2" p:UUID="00000002-b1ec-4553-aec9-835e5b724bb4" transform="1 0 0 0 1 0 0 0 1 118 118 0" printable="1"/>
 </build>
</model>"""
    settings = """<?xml version="1.0" encoding="UTF-8"?>
<config>
  <object id="2">
    <metadata key="name" value="Painted cube"/>
    <metadata key="extruder" value="1"/>
    <part id="1" subtype="normal_part">
      <metadata key="name" value="Body"/>
      <metadata key="extruder" value="0"/>
    </part>
    <part id="3" subtype="modifier_part">
      <metadata key="name" value="Modifier"/>
    </part>
  </object>
  <plate>
    <metadata key="plater_id" value="1"/>
  </plate>
</config>"""
    project = json.dumps({"filament_colour": ["#FFFFFF", "#00FF00", "#0000FF"], "printer_model": "Bambu Lab X1 Carbon"})
    write("bambu.3mf", {
        "[Content_Types].xml": CONTENT_TYPES,
        "_rels/.rels": RELS.format(thumb="Metadata/plate_1.png"),
        "3D/3dmodel.model": root,
        "3D/Objects/object_1.model": objects,
        "Metadata/model_settings.config": settings,
        "Metadata/project_settings.config": project,
        "Metadata/plate_1.png": png(rgb=(0, 200, 0)),
        "Metadata/pick_1.png": png(rgb=(1, 2, 3)),
    })


def make_prusa():
    a_v, a_t = cube(10.0)
    b_v, b_t = cube(4.0, (3, 3, 3))
    verts = a_v + b_v
    tris = a_t + [(x + 8, y + 8, z + 8) for x, y, z in b_t]
    model = f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
       xmlns:slic3rpe="http://schemas.slic3r.org/3mf/2017/06">
 <metadata name="slic3rpe:Version3mf">1</metadata>
 <metadata name="Application">PrusaSlicer-2.7.1</metadata>
 <resources>
  <object id="1" type="model">
   <mesh>
    <vertices>
{vertices_xml(verts)}
    </vertices>
    <triangles>
{triangles_xml(tris, {5: ' slic3rpe:mmu_segmentation="4"'})}
    </triangles>
   </mesh>
  </object>
 </resources>
 <build>
  <item objectid="1" transform="1 0 0 0 1 0 0 0 1 125 105 0" printable="1"/>
 </build>
</model>"""
    config = """<?xml version="1.0" encoding="UTF-8"?>
<config>
 <object id="1" instances_count="1">
  <metadata type="object" key="name" value="with modifier"/>
  <metadata type="object" key="extruder" value="0"/>
  <volume firstid="0" lastid="11">
   <metadata type="volume" key="name" value="body"/>
   <metadata type="volume" key="volume_type" value="ModelPart"/>
   <metadata type="volume" key="extruder" value="2"/>
   <mesh edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>
  </volume>
  <volume firstid="12" lastid="23">
   <metadata type="volume" key="name" value="modifier"/>
   <metadata type="volume" key="volume_type" value="ParameterModifier"/>
   <mesh edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>
  </volume>
 </object>
</config>"""
    ini = """; generated by PrusaSlicer 2.7.1
; extruder_colour = "";"#00FF00"
; filament_colour = #FF8000;#DB5182
; layer_height = 0.2
"""
    write("prusa.3mf", {
        "[Content_Types].xml": CONTENT_TYPES,
        "_rels/.rels": RELS.format(thumb="Metadata/thumbnail.png"),
        "3D/3dmodel.model": model,
        "Metadata/Slic3r_PE.config": ini,
        "Metadata/Slic3r_PE_model.config": config,
        "Metadata/thumbnail.png": png(rgb=(10, 20, 30)),
    }, stored={"3D/3dmodel.model"})


if __name__ == "__main__":
    make_cube()
    make_bambu()
    make_prusa()
