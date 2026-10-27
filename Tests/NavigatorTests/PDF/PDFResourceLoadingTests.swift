//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import PDFKit
@testable import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest

@MainActor
class PDFResourceLoadingTests: XCTestCase {
    func testLocalResourceRemainsFileBacked() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        let data = makePDF()
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let resource = DataResource(data: data, sourceURL: try XCTUnwrap(FileURL(url: url)))

        let document = await PDFNavigatorViewController.makeDocument(from: resource)

        XCTAssertEqual(document?.documentURL, url)
        XCTAssertEqual(document?.pageCount, 1)
        XCTAssertTrue(document?.page(at: 0)?.string?.contains("Resource text") == true)
    }

    func testResourceWithoutSourceURLUsesPublicationBytes() async {
        let data = makePDF()
        let resource = DataResource(data: data)

        let document = await PDFNavigatorViewController.makeDocument(from: resource)

        XCTAssertNil(document?.documentURL)
        XCTAssertEqual(document?.pageCount, 1)
        XCTAssertTrue(document?.page(at: 0)?.string?.contains("Resource text") == true)
    }

    func testReadFailureDoesNotCreateDocument() async {
        let resource = FailureResource(error: .decoding("Deliberate resource failure"))

        let document = await PDFNavigatorViewController.makeDocument(from: resource)

        XCTAssertNil(document)
    }

    func testCancelledReadDoesNotPublishLateDocument() async {
        let gate = PDFReadGate(data: makePDF())
        let resource = DataResource { await gate.read() }
        let task = Task { await PDFNavigatorViewController.makeDocument(from: resource) }
        await gate.waitUntilReading()

        task.cancel()
        await gate.finish()

        let document = await task.value
        XCTAssertNil(document)
    }

    func testReadFailureReachesNavigatorDelegate() async throws {
        let cause = NSError(domain: "ReadiumPDFResourceTests", code: 17)
        let resource = FailureResource(error: .access(.other(cause)))
        let delegate = ResourceFailureDelegate()
        let href = try XCTUnwrap(RelativeURL(path: "publication.pdf"))
        let navigator = try makeNavigator(resource: resource, href: href, delegate: delegate)

        let document = await navigator.makeDocument(at: href)

        XCTAssertNil(document)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(delegate.failures.first?.0, href)
        guard case let .access(.other(error)) = delegate.failures.first?.1 else {
            return XCTFail("Original resource error must reach the navigator delegate")
        }
        XCTAssertEqual((error as NSError).domain, cause.domain)
        XCTAssertEqual((error as NSError).code, cause.code)
    }

    func testCancelledFailureDoesNotNotifyDelegate() async throws {
        let gate = PDFReadGate(data: makePDF())
        let resource = DataResource { await gate.read() }
        let delegate = ResourceFailureDelegate()
        let href = try XCTUnwrap(RelativeURL(path: "publication.pdf"))
        let navigator = try makeNavigator(resource: resource, href: href, delegate: delegate)
        let task = Task { await navigator.makeDocument(at: href) }
        await gate.waitUntilReading()

        task.cancel()
        await gate.finish(with: .failure(.access(.other(CancellationError()))))

        let document = await task.value
        XCTAssertNil(document)
        XCTAssertTrue(delegate.failures.isEmpty)
    }

    func testMissingResourceNotifiesDelegate() async throws {
        let delegate = ResourceFailureDelegate()
        let href = try XCTUnwrap(RelativeURL(path: "publication.pdf"))
        let navigator = try makeNavigator(resource: nil, href: href, delegate: delegate)

        let document = await navigator.makeDocument(at: href)

        XCTAssertNil(document)
        XCTAssertEqual(delegate.failures.count, 1)
        XCTAssertEqual(delegate.failures.first?.0, href)
        guard case let .access(.http(.errorResponse(response))) = delegate.failures.first?.1 else {
            return XCTFail("Missing publication resource must retain its not-found error")
        }
        XCTAssertEqual(response.status, .notFound)
    }

    private func makeNavigator(resource: Resource?, href: RelativeURL, delegate: PDFNavigatorDelegate) throws -> PDFNavigatorViewController {
        let container: Container
        if let resource = resource {
            container = SingleResourceContainer(resource: resource, at: href.anyURL)
        } else {
            container = EmptyContainer()
        }
        let publication = Publication(
            manifest: Manifest(readingOrder: [Link(href: href.string, mediaType: .pdf)]),
            container: container
        )
        return try PDFNavigatorViewController(
            publication: publication,
            initialLocation: nil,
            delegate: delegate,
            httpServer: ResourceLoadingHTTPServer()
        )
    }

    private func makePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage()
            ("Resource text" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
    }
}

private actor PDFReadGate {
    private let data: Data
    private var pending: CheckedContinuation<ReadResult<Data>, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(data: Data) {
        self.data = data
    }

    func read() async -> ReadResult<Data> {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilReading() async {
        if pending != nil {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func finish(with result: ReadResult<Data>? = nil) {
        pending?.resume(returning: result ?? .success(data))
        pending = nil
    }
}

@MainActor
private class ResourceFailureDelegate: PDFNavigatorDelegate {
    var failures: [(RelativeURL, ReadError)] = []

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

    func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: RelativeURL, withError error: ReadError) {
        failures.append((href, error))
    }
}

private class ResourceLoadingHTTPServer: HTTPServer {
    func serve(at endpoint: HTTPServerEndpoint, handler: HTTPRequestHandler) throws -> HTTPURL {
        HTTPURL(string: "http://127.0.0.1/" + endpoint + "/")!
    }

    func transformResources(at endpoint: HTTPServerEndpoint, with transformer: @escaping ResourceTransformer) throws {}

    func remove(at endpoint: HTTPServerEndpoint) throws {}
}
