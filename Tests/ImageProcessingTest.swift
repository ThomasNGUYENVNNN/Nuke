//
//  ImageProcessingTest.swift
//  Nuke
//
//  Created by Alexander Grebenyuk on 06/10/15.
//  Copyright © 2015 CocoaPods. All rights reserved.
//

import XCTest
import Nuke

class ImageProcessingTest: XCTestCase {
    var manager: ImageManager!
    var mockMemoryCache: MockImageCache!
    var mockSessionManager: MockDataLoader!

    override func setUp() {
        super.setUp()

        self.mockSessionManager = MockDataLoader()
        self.mockMemoryCache = MockImageCache()
        
        self.mockSessionManager = MockDataLoader()
        let loader = ImageLoader(dataLoader: self.mockSessionManager)
        self.manager = ImageManager(loader: loader, cache: self.mockMemoryCache)
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: Applying Filters

    func testThatImageIsProcessed() {
        var request = ImageRequest(url: defaultURL)
        request.processors = [MockImageProcessor(ID: "processor1")]

        self.expect { fulfill in
            self.manager.task(with: request) {
                XCTAssertEqual($0.1.image!.nk_test_processorIDs, ["processor1"])
                fulfill()
            }.resume()
        }
        self.wait()
    }

    func testThatProcessedImageIsMemCached() {
        self.expect { fulfill in
            var request = ImageRequest(url: defaultURL)
            request.processors = [MockImageProcessor(ID: "processor1")]

            self.manager.task(with: request) {
                XCTAssertNotNil($0.1.image)
                fulfill()
            }.resume()
        }
        self.wait()

        var request = ImageRequest(url: defaultURL)
        request.processors = [MockImageProcessor(ID: "processor1")]
        guard let image = self.manager.image(for: request) else {
            XCTFail()
            return
        }
        XCTAssertEqual(image.nk_test_processorIDs, ["processor1"])
    }

    func testThatCorrectFiltersAreAppiedWhenDataTaskIsReusedForMultipleRequests() {
        var request1 = ImageRequest(url: defaultURL)
        request1.processors = [MockImageProcessor(ID: "processor1")]

        var request2 = ImageRequest(url: defaultURL)
        request2.processors = [MockImageProcessor(ID: "processor2")]

        self.expect { fulfill in
            self.manager.task(with: request1) {
                XCTAssertEqual($0.1.image!.nk_test_processorIDs, ["processor1"])
                fulfill()
            }.resume()
        }

        self.expect { fulfill in
            self.manager.task(with: request2) {
                XCTAssertEqual($0.1.image!.nk_test_processorIDs, ["processor2"])
                fulfill()
            }.resume()
        }

        self.wait { _ in
            XCTAssertEqual(self.mockSessionManager.createdTaskCount, 1)
        }
    }

    // MARK: Composing Filters

    func testThatImageIsProcessedWithFilterComposition() {
        var request = ImageRequest(url: defaultURL)
        request.processors = [MockImageProcessor(ID: "processor1"), MockImageProcessor(ID: "processor2")]

        self.expect { fulfill in
            self.manager.task(with: request) {
                XCTAssertEqual($0.1.image!.nk_test_processorIDs, ["processor1", "processor2"])
                fulfill()
                }.resume()
        }
        self.wait()
    }

    func testThatImageProcessedWithFilterCompositionIsMemCached() {
        self.expect { fulfill in
            var request = ImageRequest(url: defaultURL)
            request.processors = [MockImageProcessor(ID: "processor1"), MockImageProcessor(ID: "processor2")]
            self.manager.task(with: request) {
                XCTAssertNotNil($0.1.image)
                fulfill()
            }.resume()
        }
        self.wait()

        var request = ImageRequest(url: defaultURL)
        request.processors = [MockImageProcessor(ID: "processor1"), MockImageProcessor(ID: "processor2")]
        guard let image = self.manager.image(for: request) else {
            XCTFail()
            return
        }
        XCTAssertEqual(image.nk_test_processorIDs, ["processor1", "processor2"])
    }
    
    func testThatImageFilterWorksWithHeterogeneousFilters() {
        let composition1 = ImageProcessorComposition(processors: [MockImageProcessor(ID: "ID1"), MockParameterlessImageProcessor()])
        let composition2 = ImageProcessorComposition(processors: [MockImageProcessor(ID: "ID1"), MockParameterlessImageProcessor()])
        let composition3 = ImageProcessorComposition(processors: [MockParameterlessImageProcessor(), MockImageProcessor(ID: "ID1")])
        let composition4 = ImageProcessorComposition(processors: [MockParameterlessImageProcessor(), MockImageProcessor(ID: "ID1"), MockImageProcessor(ID: "ID2")])
        XCTAssertEqual(composition1, composition2)
        XCTAssertNotEqual(composition1, composition3)
        XCTAssertNotEqual(composition1, composition4)
    }
}
