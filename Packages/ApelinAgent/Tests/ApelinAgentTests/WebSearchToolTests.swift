@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// apelin_web_search's six sources: the three that were there first keep their
/// lines, and the three added beside them (DuckDuckGo, Stack Overflow,
/// Wikipedia) are read from saved pages and, end to end, through `WebStub`.
@Suite("apelin_web_search")
struct WebSearchToolTests {
    /// Every search here goes to `WebStub`, never the network.
    private static let web: WebSearch = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebStub.self]
        return WebSearch(configuration: configuration)
    }()

    private static func search(_ query: String, limit: Int? = nil) async throws -> String {
        var arguments: [String: JSONValue] = ["query": .string(query)]
        if let limit {
            arguments["limit"] = .int(limit)
        }
        return try await web.search(.object(arguments))
    }

    // MARK: Parsing a saved page

    @Test
    func `DuckDuckGo's page reads as its results, redirects unwrapped`() {
        let html = """
        <div class="result results_links results_links_deep web-result">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Fuikit%2Fuiwindow&amp;rut=abc">UIWindow | Apple Developer &amp; Documentation</a>
          </h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Fuikit%2Fuiwindow">The <b>window</b> object that manages and coordinates an app&#39;s windows.</a>
        </div>
        <div class="result results_links results_links_deep web-result">
          <h2 class="result__title">
            <a rel="nofollow" class="result__a" href="https://example.test/second">A second &lt;result&gt;</a>
          </h2>
        </div>
        <a class="result__a" href="javascript:void(0)">Not a page</a>
        """
        let hits = WebSearch.duckDuckGoHits(html: html, limit: 5)
        #expect(hits.count == 2, "three anchors name results, one of them not a page")
        #expect(hits.first?.title == "UIWindow | Apple Developer & Documentation")
        #expect(hits.first?.url == "https://developer.apple.com/documentation/uikit/uiwindow")
        #expect(hits.first?.detail == "The window object that manages and coordinates an app's windows.")
        #expect(hits.last?.title == "A second <result>")
        #expect(hits.last?.url == "https://example.test/second")
        #expect(hits.last?.detail == nil, "a result with no snippet keeps no detail")
    }

    @Test
    func `DuckDuckGo's limit stops at the last result it keeps`() {
        let html = (1 ... 4).map { index in
            "<a class=\"result__a\" href=\"https://example.test/\(index)\">Result \(index)</a>"
                + "<a class=\"result__snippet\" href=\"#\">Snippet \(index)</a>"
        }.joined()
        let hits = WebSearch.duckDuckGoHits(html: html, limit: 2)
        #expect(hits.map(\.title) == ["Result 1", "Result 2"])
        #expect(hits.map(\.detail) == ["Snippet 1", "Snippet 2"])
    }

    @Test
    func `Wikipedia's answer reads as its articles`() {
        let json = Data("""
        {"batchcomplete":"","query":{"searchinfo":{"totalhits":4},"search":[
          {"ns":0,"title":"XcodeGhost","pageid":48467799,"snippet":"Then the malicious files will add extra code in <span class=\\"searchmatch\\">UIWindow</span> class and UIDevice class. The <span class=\\"searchmatch\\">UIWindow</span> class is &quot;an object that manages and coordinates the"},
          {"ns":0,"title":"Chain-of-responsibility pattern","pageid":23830136,"snippet":"objects (NSViewController/UIViewController), window objects"}
        ]}}
        """.utf8)
        let hits = WebSearch.wikipediaHits(json: json, limit: 5)
        #expect(hits.count == 2)
        #expect(hits.first?.title == "XcodeGhost")
        #expect(hits.first?.url == "https://en.wikipedia.org/?curid=48467799")
        #expect(hits.first?.detail?.contains("<span") == false, "a snippet is text, not markup")
        #expect(hits.first?.detail.contains("The UIWindow class is \"an object") == true)
    }

    @Test
    func `Stack Overflow's answer reads as its questions`() {
        let json = Data("""
        {"items":[
          {"tags":["ios","uikit"],"is_answered":true,"score":12,
           "title":"How to get the &quot;key window&quot; in iOS 16?",
           "link":"https://stackoverflow.com/questions/42056257"},
          {"tags":["swift"],"is_answered":false,"score":0,
           "title":"A question nobody answered",
           "link":"https://stackoverflow.com/questions/1"}
        ],"has_more":false}
        """.utf8)
        let hits = WebSearch.stackExchangeHits(json: json, limit: 5)
        #expect(hits.count == 2)
        // The API escapes the quote marks in a title; a source answers what it
        // wrote, and `lines` writes the references out.
        #expect(hits.first?.title == "How to get the &quot;key window&quot; in iOS 16?")
        #expect(WebSearch.lines(hits, limit: 5)?.contains("- [How to get the \"key window\" in iOS 16?](") == true)
        #expect(hits.first?.detail == "12 points, answered — ios, uikit")
        #expect(hits.last?.detail == "0 points, no answer yet — swift")
    }

    @Test
    func `an answer that does not read costs its source, not the search`() {
        #expect(WebSearch.wikipediaHits(json: Data("not json".utf8), limit: 5).isEmpty)
        #expect(WebSearch.stackExchangeHits(json: Data("{}".utf8), limit: 5).isEmpty)
        #expect(WebSearch.duckDuckGoHits(html: "", limit: 5).isEmpty)
    }

    // MARK: End to end

    @Test
    func `every source has its heading, and an empty one says so`() async throws {
        let report = try await Self.search("a query no stub answers")
        for heading in [
            "Web results (DuckDuckGo)",
            "GitHub repositories and issues",
            "Hacker News stories and comments",
            "Reddit posts and comments",
            "Stack Overflow questions",
            "Wikipedia articles",
        ] {
            #expect(report.contains("## \(heading)"), "\(heading) is missing")
        }
        #expect(!report.contains("- ["), "no stub answered, so there is nothing to link")
    }

    @Test
    func `the added sources answer through the session`() async throws {
        let query = "uikit key window \(UUID().uuidString.prefix(8))"
        let duckDuckGoURL = try #require(WebSearch.duckDuckGoURL(query: query))
        let wikipediaURL = try #require(WebSearch.wikipediaURL(query: query, limit: 5))
        let stackExchangeURL = try #require(WebSearch.stackExchangeURL(query: query, limit: 5))
        WebStub.serve(duckDuckGoURL.absoluteString, .html("""
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fdocumentation%2Fuikit%2Fuiwindow">UIWindow</a>
        <a class="result__snippet" href="#">A window that manages an app's screen.</a>
        """))
        WebStub.serve(wikipediaURL.absoluteString, WebStub.Reply(
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data("""
            {"query":{"search":[{"title":"UIWindow","pageid":42,"snippet":"a window"}]}}
            """.utf8),
        ))
        WebStub.serve(stackExchangeURL.absoluteString, WebStub.Reply(
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data("""
            {"items":[{"is_answered":true,"score":3,"tags":["ios"],"title":"Key window?",
            "link":"https://stackoverflow.com/questions/42"}]}
            """.utf8),
        ))

        let report = try await Self.search(query)
        #expect(report.contains("- [UIWindow](https://developer.apple.com/documentation/uikit/uiwindow): A window that manages an app's screen."))
        #expect(report.contains("- [UIWindow](https://en.wikipedia.org/?curid=42)"))
        #expect(report.contains("- [Key window?](https://stackoverflow.com/questions/42): 3 points, answered"))
        #expect(report.contains("## GitHub repositories and issues"))
        #expect(report.hasSuffix("Use apelin_web_fetch on a result URL to read the page."))
    }

    @Test
    func `a limit keeps each source to that many results`() async throws {
        let query = "limits \(UUID().uuidString.prefix(8))"
        let url = try #require(WebSearch.duckDuckGoURL(query: query))
        WebStub.serve(url.absoluteString, .html((1 ... 5).map { index in
            "<a class=\"result__a\" href=\"https://example.test/\(index)\">Result \(index)</a>"
        }.joined()))
        let report = try await Self.search(query, limit: 2)
        #expect(report.contains("- [Result 1](https://example.test/1)"))
        #expect(report.contains("- [Result 2](https://example.test/2)"))
        #expect(!report.contains("Result 3"))
    }

    @Test
    func `a title that would break its link is written plainly`() {
        let line = WebSearch.lines([
            WebSearch.SearchHit(title: "a [bracketed] title", url: "https://example.test/x", detail: nil),
        ], limit: 5)
        #expect(line == "- [a (bracketed) title](https://example.test/x)")
        #expect(WebSearch.lines([], limit: 5) == nil)
    }

    @Test
    func `a source's link is only offered when it is a page`() {
        #expect(WebSearch.destination("//example.test/a") == "https://example.test/a")
        #expect(WebSearch.destination("javascript:void(0)") == "")
        #expect(WebSearch.destination("/relative/only") == "")
        // DuckDuckGo's redirect hands the real address in `uddg`.
        #expect(WebSearch.destination(
            "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.test%2Fb&rut=1",
        ) == "https://example.test/b")
    }
}