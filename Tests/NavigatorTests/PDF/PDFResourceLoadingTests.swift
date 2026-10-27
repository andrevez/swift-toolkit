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

    func finish() {
        pending?.resume(returning: .success(data))
        pending = nil
    }
}
