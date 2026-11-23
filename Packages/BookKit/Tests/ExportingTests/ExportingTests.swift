import Testing
@testable import Exporting

@Test func exportingModuleLoads() {
    #expect(ExportFileName.make("A/B", ext: "md") == "A B.md")
}
