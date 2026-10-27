import XCTest
@testable import LokalBot

final class EmailTextTests: XCTestCase {
    // MARK: Addresses

    func testAddressListsKeepQuotedCommasAndFlattenGroups() {
        let parsed = EmailText.addresses(
            #""Petrović, Ana" <Ana.Petrovic@Example.com>, bob@example.com, Team: carol@x.org, dan@y.org;, not-an-address"#)
        XCTAssertEqual(parsed, [
            EmailAddress(name: "Petrović, Ana", address: "ana.petrovic@example.com"),
            EmailAddress(name: nil, address: "bob@example.com"),
            EmailAddress(name: nil, address: "carol@x.org"),
            EmailAddress(name: nil, address: "dan@y.org"),
        ])
    }

    func testDisplayNamesDecodeEncodedWords() {
        XCTAssertEqual(EmailText.address("=?UTF-8?B?TWlsb8WhIMSQb3LEkWV2acSH?= <milos@example.rs>"),
                       EmailAddress(name: "Miloš Đorđević", address: "milos@example.rs"))
        XCTAssertNil(EmailText.address("Undisclosed recipients:;"))
        XCTAssertNil(EmailText.address("<@example.com>"))
    }

    // MARK: Encoded words

    func testEncodedWordsInBothEncodingsAndCharsets() {
        XCTAssertEqual(EmailText.decodeEncodedWords("=?utf-8?Q?Sastanak_u_=C4=8Detvrtak?="), "Sastanak u četvrtak")
        // Adjacent encoded words join without the space between them.
        XCTAssertEqual(EmailText.decodeEncodedWords("=?UTF-8?Q?Pla?= =?UTF-8?Q?n?= for Q4"), "Plan for Q4")
        XCTAssertEqual(EmailText.decodeEncodedWords("=?windows-1250?Q?=E8ovek?="), "čovek")
        XCTAssertEqual(EmailText.decodeEncodedWords("=?ISO-8859-2?B?xOjl?="), "Äčĺ")
        XCTAssertEqual(EmailText.decodeEncodedWords("Plain subject =? not encoded"), "Plain subject =? not encoded")
    }

    func testBodiesDecodeInTheirDeclaredCharset() throws {
        let windows1250 = try XCTUnwrap("Šta ćemo?".data(using: .windowsCP1250))
        XCTAssertEqual(EmailText.decode(windows1250, charset: "windows-1250"), "Šta ćemo?")
        XCTAssertEqual(EmailText.charset(fromContentType: #"text/plain; format=flowed; charset="ISO-8859-2""#),
                       "ISO-8859-2")
        // An unknown charset falls back to UTF-8, then Latin-1, never to nothing.
        XCTAssertEqual(EmailText.decode(Data("ok".utf8), charset: "x-unknown"), "ok")
        XCTAssertEqual(EmailText.decode(Data([0xE9]), charset: nil), "é")
    }

    // MARK: HTML

    func testHTMLBecomesReadableTextWithoutScriptsOrStyles() {
        let html = """
        <html><head><title>Ignore</title><style>p { color: red }</style></head><body>
        <p>Hi&nbsp;Ana,</p><script>track()</script>
        <p>Agenda:<br>first &amp; second</p>
        <ul><li>Budget</li><li>Hiring</li></ul>
        <img src="https://tracker.example/pixel.gif">
        <p>Price &lt; 5&#8364; &#x2014; ok</p>
        </body></html>
        """
        XCTAssertEqual(EmailText.plainText(fromHTML: html), """
        Hi Ana,

        Agenda:
        first & second

        • Budget
        • Hiring

        Price < 5€ — ok
        """)
    }

    func testQuotedHistoryKeepsAQuotePrefix() {
        let html = "<div>Sounds good.</div><div class=\"gmail_quote\">On Mon, Ana wrote:"
            + "<blockquote>Can we move it to Friday?<br>Thanks</blockquote></div>"
        XCTAssertEqual(EmailText.plainText(fromHTML: html), """
        Sounds good.
        On Mon, Ana wrote:
        > Can we move it to Friday?
        > Thanks
        """)
    }
}
