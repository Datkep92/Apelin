import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

require(GoogleSheetID.parse("1AbCxyz-123") == "1AbCxyz-123", "A bare ID stays")
require(
    GoogleSheetID.parse("  https://docs.google.com/spreadsheets/d/1AbCxyz-123/edit#gid=0  ") == "1AbCxyz-123",
    "A full link with a fragment yields its ID"
)
require(
    GoogleSheetID.parse("https://docs.google.com/spreadsheets/d/1AbCxyz-123") == "1AbCxyz-123",
    "A link without a trailing slash yields its ID"
)
require(
    GoogleSheetID.parse("https://example.com/spreadsheets/d/other") == "https://example.com/spreadsheets/d/other",
    "Another host is not a spreadsheet link"
)
print("ok: GoogleSheetID")
