import XCTest
@testable import ThreeMFKit

final class ThreeMFKitTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String = "3mf") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func color(_ hex: String) -> RGBAColor { RGBAColor(hex: hex)! }

    // MARK: - Plain 3MF

    func testCubeWithBaseMaterials() throws {
        let model = try ThreeMFReader.load(url: fixture("cube"))
        XCTAssertEqual(model.unit, .inch)
        XCTAssertEqual(model.objectCount, 1)
        XCTAssertEqual(model.triangleCount, 12)
        XCTAssertEqual(model.metadataValue("Title"), "Test Cube")
        XCTAssertEqual(model.metadataValue("Designer"), "A & B")

        let size = try XCTUnwrap(model.sizeInMillimeters)
        XCTAssertEqual(size.x, 25.4, accuracy: 1e-6)
        XCTAssertEqual(size.z, 25.4, accuracy: 1e-6)

        let bounds = try XCTUnwrap(model.bounds)
        XCTAssertEqual(bounds.min.x, 4, accuracy: 1e-6)
        XCTAssertEqual(bounds.min.y, 5, accuracy: 1e-6)

        let instance = try XCTUnwrap(model.instances.first)
        let colors = model.resolvedColors(for: instance)
        XCTAssertEqual(Set(colors.compactMap { $0 }), [color("#FF0000"), color("#0000FF")])
        XCTAssertEqual(colors[instance.mesh.paletteIndex(ofTriangle: 0)], color("#0000FF"))
        XCTAssertEqual(colors[instance.mesh.paletteIndex(ofTriangle: 1)], color("#FF0000"))

        let thumbnail = try XCTUnwrap(ThreeMFReader.thumbnailData(url: fixture("cube")))
        XCTAssertEqual(Array(thumbnail.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - Bambu Studio / OrcaSlicer

    func testBambuProjectComponentsAndPainting() throws {
        let model = try ThreeMFReader.load(url: fixture("bambu"))
        XCTAssertEqual(model.metadataValue("Application"), "BambuStudio-01.09.00.70")
        XCTAssertEqual(model.filamentColors, [color("#FFFFFF"), color("#00FF00"), color("#0000FF")])

        // The modifier part must be skipped.
        XCTAssertEqual(model.instances.count, 1)
        XCTAssertEqual(model.triangleCount, 12)

        let bounds = try XCTUnwrap(model.bounds)
        XCTAssertEqual(bounds.min, SIMD3(118, 118, 0))
        XCTAssertEqual(bounds.max, SIMD3(138, 138, 20))

        let instance = model.instances[0]
        XCTAssertEqual(instance.extruder, 1)
        XCTAssertEqual(instance.objectName, "Painted cube")
        let colors = model.resolvedColors(for: instance)
        func colorOf(_ t: Int) -> RGBAColor? { colors[instance.mesh.paletteIndex(ofTriangle: t)] }
        XCTAssertEqual(colorOf(0), color("#00FF00"))
        XCTAssertEqual(colorOf(1), color("#00FF00"))
        XCTAssertEqual(colorOf(2), color("#0000FF"))
        XCTAssertEqual(colorOf(3), color("#FFFFFF"))

        // plate_1.png (green), never pick_1.png.
        let thumbnail = try XCTUnwrap(ThreeMFReader.thumbnailData(url: fixture("bambu")))
        XCTAssertGreaterThan(thumbnail.count, 20)
    }

    func testBambuPlatesAndSliceInfo() throws {
        let url = try fixture("bambu_plates")
        let model = try ThreeMFReader.load(url: url)
        let project = model.project

        XCTAssertEqual(project.printerName, "Bambu Lab P1S 0.4 nozzle")  // printer_model is empty
        XCTAssertEqual(project.nozzleDiameter, "0.4")
        XCTAssertEqual(project.layerHeight, "0.2")
        XCTAssertEqual(project.filamentTypes, ["PLA", "PETG"])

        XCTAssertEqual(project.plates.map(\.index), [1, 2])
        XCTAssertEqual(project.plates[1].name, "Big & small")
        XCTAssertEqual(project.plates.map(\.objectCount), [1, 2])
        XCTAssertNotNil(project.plates[0].thumbnail)  // no _small.png → the full image
        XCTAssertNotNil(project.plates[1].image)
        XCTAssertLessThan(try XCTUnwrap(project.plates[1].thumbnail).count, try XCTUnwrap(project.plates[1].image).count)

        // Only plate 2 is sliced.
        XCTAssertNil(project.plates[0].slice)
        let slice = try XCTUnwrap(project.plates[1].slice)
        XCTAssertEqual(slice.printTime, 5400)
        XCTAssertEqual(slice.weight, 30.5)
        XCTAssertEqual(slice.meters ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(slice.filaments.map(\.type), ["PLA", "PETG"])
        XCTAssertEqual(slice.filaments[1].color, color("#FF0000"))
        XCTAssertEqual(project.totalPrintTime, 5400)
        XCTAssertEqual(project.slicedPlates.count, 1)

        // Build items are split between the plates: the second copy of object 2 is on plate 2.
        XCTAssertEqual(model.instances.map(\.plate), [1, 2, 2])
        let first = model.onPlate(1)
        XCTAssertEqual(first.instances.count, 1)
        XCTAssertEqual(first.objectCount, 1)
        XCTAssertEqual(try XCTUnwrap(first.sizeInMillimeters).x, 10, accuracy: 1e-6)
        let second = model.onPlate(2)
        XCTAssertEqual(second.triangleCount, 24)
        XCTAssertEqual(try XCTUnwrap(second.bounds).min.x, 400, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(second.sizeInMillimeters).x, 80, accuracy: 1e-6)

        // The same data without loading meshes, and the cheap summary for the library list.
        let standalone = try ThreeMFReader.printProject(url: url)
        XCTAssertEqual(standalone.plates.count, 2)
        XCTAssertEqual(standalone.plates[1].slice?.printTime, 5400)
        let summary = try XCTUnwrap(ThreeMFReader.sliceSummary(url: url))
        XCTAssertEqual(summary.printTime, 5400)
        XCTAssertEqual(summary.weight, 30.5)
        XCTAssertNil(ThreeMFReader.sliceSummary(url: try fixture("bambu")))
    }

    func testPrinterNameFallbacks() {
        XCTAssertEqual(PrintProjectParser.bambuPrinterName(code: "N7"), "Bambu Lab P2S")
        let ini = Data("; printer_settings_id = Original Prusa MK4 0.4 nozzle\n; nozzle_diameter = 0.4,0.6\n; filament_type = PETG;PLA\n".utf8)
        let settings = PrintProjectParser.parsePrusaProjectSettings(ini)
        XCTAssertEqual(settings.printerName, "Original Prusa MK4 0.4 nozzle")
        XCTAssertEqual(settings.nozzleDiameter, "0.4")
        XCTAssertEqual(settings.filamentTypes, ["PETG", "PLA"])
    }

    // MARK: - PrusaSlicer

    func testPrusaVolumesAndColors() throws {
        let model = try ThreeMFReader.load(url: fixture("prusa"))
        XCTAssertEqual(model.project.layerHeight, "0.2")
        XCTAssertTrue(model.project.plates.isEmpty)
        XCTAssertEqual(model.filamentColors, [color("#FF8000"), color("#00FF00")])
        // 24 triangles in the file, 12 of them belong to a modifier volume.
        XCTAssertEqual(model.triangleCount, 12)

        let instance = try XCTUnwrap(model.instances.first)
        let colors = model.resolvedColors(for: instance)
        func colorOf(_ t: Int) -> RGBAColor? { colors[instance.mesh.paletteIndex(ofTriangle: t)] }
        XCTAssertEqual(colorOf(0), color("#00FF00"))  // volume extruder 2
        XCTAssertEqual(colorOf(5), color("#FF8000"))  // painted with extruder 1

        let size = try XCTUnwrap(model.sizeInMillimeters)
        XCTAssertEqual(size.x, 10, accuracy: 1e-6)
    }

    // MARK: - STL / OBJ

    func testSTLBinaryAndASCII() throws {
        // Binary, although the header starts with "solid".
        let binary = try ModelReader.load(url: fixture("cube", "stl"))
        XCTAssertEqual(binary.triangleCount, 12)
        XCTAssertEqual(binary.objectCount, 1)
        XCTAssertEqual(try XCTUnwrap(binary.bounds).min.x, 5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(binary.sizeInMillimeters).x, 20, accuracy: 1e-6)
        XCTAssertEqual(binary.instances.first?.objectName, "cube")

        let ascii = try ModelReader.load(url: fixture("cube_ascii", "stl"))
        XCTAssertEqual(ascii.triangleCount, 12)
        XCTAssertEqual(try XCTUnwrap(ascii.sizeInMillimeters).z, 10, accuracy: 1e-6)

        XCTAssertThrowsError(try STLReader.parse(Data("hello".utf8), key: "x"))
    }

    func testOBJWithMaterials() throws {
        let model = try ModelReader.load(url: fixture("two_cubes", "obj"))
        XCTAssertEqual(model.triangleCount, 24)  // 2 × 6 quads
        XCTAssertEqual(model.objectCount, 2)
        XCTAssertEqual(try XCTUnwrap(model.sizeInMillimeters).x, 30, accuracy: 1e-6)

        let instance = try XCTUnwrap(model.instances.first)
        let colors = model.resolvedColors(for: instance)
        XCTAssertEqual(colors[instance.mesh.paletteIndex(ofTriangle: 0)], color("#FF0000"))
        let green = try XCTUnwrap(colors[instance.mesh.paletteIndex(ofTriangle: 12)])
        XCTAssertEqual(green.g, 1)
        XCTAssertEqual(green.a, 0.5, accuracy: 1e-6)

        XCTAssertEqual(ModelFileFormat(url: URL(fileURLWithPath: "/a/B.STL")), .stl)
        XCTAssertNil(ModelFileFormat(url: URL(fileURLWithPath: "/a/b.gcode")))
    }

    // MARK: - Building blocks

    func testPaintDecoder() {
        XCTAssertEqual(PaintDecoder.dominantState(hex: ""), 0)
        XCTAssertEqual(PaintDecoder.dominantState(hex: "4"), 1)
        XCTAssertEqual(PaintDecoder.dominantState(hex: "8"), 2)
        XCTAssertEqual(PaintDecoder.dominantState(hex: "0C"), 3)
        XCTAssertEqual(PaintDecoder.dominantState(hex: "1C"), 4)
        // Split in two halves, both extruder 1.
        XCTAssertEqual(PaintDecoder.dominantState(hex: "441"), 1)
        // Split in four quarters, only one painted → mostly unpainted.
        XCTAssertEqual(PaintDecoder.dominantState(hex: "00083"), 0)
        // Half = extruder 1; the other half split into quarters, 3 of them extruder 2 (3/8 < 1/2).
        XCTAssertEqual(PaintDecoder.dominantState(hex: "4088831"), 1)
    }

    func testTransformComposition() throws {
        let translate = try XCTUnwrap(Transform3D(string: "1 0 0 0 1 0 0 0 1 10 20 30"))
        let rotateZ90 = try XCTUnwrap(Transform3D(string: "0 1 0 -1 0 0 0 0 1 0 0 0"))
        // Rotate first, then translate.
        let combined = rotateZ90.then(translate)
        let p = combined.apply(1, 0, 0)
        XCTAssertEqual(p.0, 10, accuracy: 1e-9)
        XCTAssertEqual(p.1, 21, accuracy: 1e-9)
        XCTAssertEqual(p.2, 30, accuracy: 1e-9)
        XCTAssertNil(Transform3D(string: "1 2 3"))
    }

    func testXMLScannerAndNumbers() throws {
        let xml = """
        <?xml version="1.0"?><!-- comment --><a x="1.5e2" y='-0.25' p:path="/3D/x.model"><b/>t&amp;x</a>
        """
        var names: [String] = []
        var text = ""
        try XMLBytes.with(Data(xml.utf8)) { doc in
            try doc.scan { tag in
                names.append(doc.string(tag.name) + (tag.kind == .end ? "/" : ""))
                if doc.equals(tag.name, "a"), tag.kind == .start {
                    XCTAssertEqual(doc.attribute(tag, "x").flatMap(doc.double), 150)
                    XCTAssertEqual(doc.attribute(tag, "y").flatMap(doc.double), -0.25)
                    XCTAssertEqual(doc.attributeString(tag, "path"), "/3D/x.model")
                }
                if tag.kind == .end { text = doc.string(tag.textBefore) }
            }
        }
        XCTAssertEqual(names, ["a", "b", "a/"])
        XCTAssertEqual(text, "t&x")
    }

    func testColorParsing() {
        XCTAssertEqual(RGBAColor(hex: "#FF000080")?.a ?? 0, 128.0 / 255.0, accuracy: 1e-6)
        XCTAssertEqual(RGBAColor(hex: "00ff00")?.g, 1)
        XCTAssertNil(RGBAColor(hex: "#12"))
        XCTAssertEqual(RGBAColor(hex: "#0A0B0C")?.hexString, "#0A0B0C")
    }

    func testNotAZip() {
        XCTAssertThrowsError(try ThreeMFReader.load(data: Data("hello".utf8)))
    }
}
