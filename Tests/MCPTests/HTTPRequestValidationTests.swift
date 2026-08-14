import Testing

@testable import MCP

@Suite("HTTP request media validation")
struct HTTPRequestValidationTests {
    @Test("Accept media ranges are case-insensitive and allow OWS")
    func acceptCaseAndOWS() {
        let value =
            " Application/JSON ,\tText/Event-Stream; q=1 "

        #expect(acceptStatus(value) == nil)
    }

    @Test("Accept parameters participate in representation matching")
    func acceptParameters() {
        #expect(
            acceptStatus("application/json;profile=v1, text/event-stream") == 406
        )
        #expect(
            acceptStatus("application/json;q=1;profile=v1, text/event-stream") == 406
        )
        #expect(
            acceptStatus(
                "application/json;profile=v1, application/json, text/event-stream"
            ) == nil
        )
    }

    @Test("Accept rejects suffix lookalikes")
    func acceptSuffixLookalikes() {
        for value in [
            "application/jsonwhatever, text/event-stream",
            "application/json, text/event-streamx",
            "application/problem+json, text/event-stream",
        ] {
            #expect(acceptStatus(value) == 406)
        }
    }

    @Test("Accept supports exact, type wildcard, and global wildcard ranges")
    func acceptWildcards() {
        for value in [
            "application/json, text/event-stream",
            "application/*, text/*",
            "*/*",
            "application/*, text/event-stream",
        ] {
            #expect(acceptStatus(value) == nil)
        }

        #expect(acceptStatus("application/*", mode: .jsonOnly) == nil)
        #expect(acceptStatus("text/*", method: "GET") == nil)
    }

    @Test("A more specific q=0 exclusion overrides broader wildcards")
    func acceptQualityPrecedence() {
        #expect(
            acceptStatus("*/*;q=1, application/json;q=0, text/event-stream") == 406
        )
        #expect(
            acceptStatus("*/*;q=1, text/event-stream;q=0, application/json") == 406
        )
        #expect(
            acceptStatus("*/*;q=1, application/*;q=0", mode: .jsonOnly) == 406
        )
        #expect(
            acceptStatus("*/*;q=0, application/json;q=0.5, text/event-stream;q=1") == nil
        )
    }

    @Test("Duplicate Accept ranges require consistent quality")
    func duplicateAcceptRanges() {
        #expect(
            acceptStatus(
                "application/json;q=0.8, application/json;q=0.8, text/event-stream"
            ) == nil
        )
        #expect(
            acceptStatus(
                "application/json;q=1, application/json;q=0, text/event-stream"
            ) == 406
        )
    }

    @Test("Invalid quality values and malformed Accept syntax are rejected")
    func malformedAccept() {
        for value in [
            "application/json;q=1.1, text/event-stream",
            "application/json;q=0.1234, text/event-stream",
            "application/json;q=bogus, text/event-stream",
            "application/json;q=\"1\", text/event-stream",
            "application/json, */json",
            "application /json, text/event-stream",
            "application/json;profile=\"unterminated, text/event-stream",
            "application/json; q =1, text/event-stream",
            "",
        ] {
            #expect(acceptStatus(value) == 406)
        }
    }

    @Test("Empty list elements and parameters are ignored, not rejected")
    func acceptEmptyListElements() {
        // RFC 9110 §5.6.1: recipients must parse and ignore empty list elements.
        for value in [
            "application/json, text/event-stream,",
            "application/json, , text/event-stream",
            ",application/json, text/event-stream",
            "application/json,,text/event-stream",
        ] {
            #expect(acceptStatus(value) == nil)
        }

        // RFC 9110 §5.6.6: each parameter in the list is optional.
        #expect(acceptStatus("application/json;, text/event-stream") == nil)
        #expect(contentTypeStatus("application/json;") == nil)

        // A value that carries no media range at all is still unacceptable.
        #expect(acceptStatus(",") == 406)
        #expect(acceptStatus(" , ") == 406)
    }

    @Test("Content-Type is case-insensitive, exact, and parameter-aware")
    func contentTypeParsing() {
        for value in [
            "application/json",
            "Application/JSON; charset=utf-8",
            " application/json ; profile=\"weather v1\" ",
            "application/json; profile=\"weather, alerts\"",
        ] {
            #expect(contentTypeStatus(value) == nil)
        }

        for value in [
            "application/jsonwhatever",
            "application/problem+json",
            "application/*",
            "application /json",
            "application/json, text/plain",
            "application/json; charset",
            "application/json; profile=\"unterminated",
            "",
        ] {
            #expect(contentTypeStatus(value) == 415)
        }
    }

    private func acceptStatus(
        _ value: String,
        method: String = "POST",
        mode: AcceptHeaderValidator.Mode = .sseRequired
    ) -> Int? {
        AcceptHeaderValidator(mode: mode).validate(
            HTTPRequest(method: method, headers: [HTTPHeaderName.accept: value]),
            context: HTTPValidationContext(httpMethod: method)
        )?.statusCode
    }

    private func contentTypeStatus(_ value: String) -> Int? {
        ContentTypeValidator().validate(
            HTTPRequest(
                method: "POST",
                headers: [HTTPHeaderName.contentType: value]
            ),
            context: HTTPValidationContext(httpMethod: "POST")
        )?.statusCode
    }
}
