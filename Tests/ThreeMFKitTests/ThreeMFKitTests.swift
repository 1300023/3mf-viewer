import XCTest
@testable import ThreeMFKit

final class ThreeMFKitTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "3mf", subdirectory: "Fixtures"))
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

    // MARK: - PrusaSlicer

    func testPrusaVolumesAndColors() throws {
        let model = try ThreeMFReader.load(url: fixture("prusa"))
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
