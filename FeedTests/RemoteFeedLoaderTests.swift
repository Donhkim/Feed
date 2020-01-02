//
//  Copyright © 2018 Essential Developer. All rights reserved.
//

#if DEBUG
import XCTest
#endif

import Foundation

//: ***
//: *FeedItem.swift*
public struct FeedItem: Equatable {
    let id: UUID
    let description: String?
    let location: String?
    let imageURL: URL
}

//: ***
//: *FeedItemsMapper.swift*
internal final class FeedItemsMapper {
    private struct Root: Decodable {
        let items: [Item]
        
        var feed: [FeedItem] {
            return items.map {$0.item}
        }
    }
    
    private struct Item: Decodable {
        let id: UUID
        let description: String?
        let location: String?
        let image: URL
        
        var item: FeedItem {
            return FeedItem(id: id, description: description, location: location, imageURL: image)
        }
    }
    
    private static var OK_200 : Int {return 200}
    
    internal static func map(_ data:Data, _ response: HTTPURLResponse) -> RemoteFeedLoader.Result {
        guard response.statusCode == OK_200,
        let root = try? JSONDecoder().decode(Root.self, from: data) else {
            return .failure(RemoteFeedLoader.Error.invalidData)
        }
        
        return .success(root.feed)
    }
}

//: ***
//: *FeedLoader.swift*
public enum LoadFeedResult {
    case success([FeedItem])
    case failure(Error)
}

public protocol FeedLoader {
    func load(completion: @escaping (LoadFeedResult) -> Void)
}

//: ***
//: *RemoteFeedLoader.swift*
public final class RemoteFeedLoader: FeedLoader {
    let client: HTTPClient
    let url: URL
    
    public enum Error: Swift.Error {
        case connectivity
        case invalidData
    }
    
    public typealias Result = LoadFeedResult
    
    init(url: URL, client: HTTPClient) {
        self.url = url
        self.client = client
    }
    
    public func load(completion: @escaping (Result) -> Void) {
        client.get(from: url) { [weak self] result in
            guard self != nil else { return }
            
            switch result {
            case let .success(data, response):
                completion(FeedItemsMapper.map(data, response))
            case .failure:
                completion(.failure(RemoteFeedLoader.Error.connectivity))
            }
        }
    }
}


//: ***
//: *RemoteFeedLoaderTests.swift*
class RemoteFeedLoaderTests: XCTestCase {
    func test_init_doesNotRequestDataFromURL() {
        let (_, client) = makeSUT()
        XCTAssertTrue(client.requestedURLs.isEmpty)
    }
    
    func test_load_requestsDataFromURL() {
        let url = URL(string: "https://a-given-url.com")!
        let (sut, client) = makeSUT(url: url)
        sut.load { _ in }
        XCTAssertEqual(client.requestedURLs, [url])
    }
    
    func test_loadTwice_requestsDataFromURLTwice() {
        let url = URL(string: "https://a-given-url.com")!
        let (sut, client) = makeSUT(url: url)
        sut.load { _ in }
        sut.load { _ in }
        XCTAssertEqual(client.requestedURLs, [url, url])
    }
    
    func test_load_deliversErrorOnClientError() {
        let (sut, client) = makeSUT()
        expect(sut, toCompleteWith: failure(.connectivity), when: {
                let clientError = NSError(domain: "Test", code: 0)
                client.complete(with: clientError)
        })
    }
    
    func test_load_deliversErrorOnNon200HTTPResponse() {
        let (sut, client) = makeSUT()
        
        let samples = [199, 201, 300, 400]
        samples.enumerated().forEach { index, code in
            expect(sut, toCompleteWith: failure(.invalidData), when: {
                let data = makeItemsJSON([])
                client.complete(withStatusCode:code, data: data, at:index)
            })
        }
    }
    
    func test_load_deliversErrorOn200HTTPResponseWithInvalidJSON() {
        let (sut, client) = makeSUT()
        
        expect(sut, toCompleteWith: failure(.invalidData), when: {
                let invalidJSON = Data("invalid json".utf8)
                client.complete(withStatusCode:200, data:invalidJSON)
        })
    }
    
    func test_load_deliversNoItemsOn200HTTPResponseWithEmptyJSONList() {
        let (sut, client) = makeSUT()
        
        expect(sut, toCompleteWith: .success([]), when: {
            let emptyJSONList = makeItemsJSON([])
            client.complete(withStatusCode: 200, data: emptyJSONList)
        })
    }
    
    func test_load_deliversItemsOn200HTTPResponseWithJSONItems() {
        let (sut, client) = makeSUT()
        let item1 = makeItem(id: UUID(), imageURL: URL(string: "https://a-url.com")!)
        
        let item2 = makeItem(id: UUID(), description: "a description", location: "a location", imageURL: URL(string: "https://another-url.com")!)

        let items = [item1.model, item2.model]
        
        expect(sut, toCompleteWith: .success(items), when: {
            let json = makeItemsJSON([item1.json, item2.json])
            client.complete(withStatusCode: 200, data: json)
        })
    }
    
    func test_load_doesNotDeliverResultAfterSUTInstanceHasBeenDeallocated() {
        let url = URL(string: "https://any-url.com")!
        let client = HTTPClientSpy()
        var sut: RemoteFeedLoader? = RemoteFeedLoader(url: url, client: client)
        
        var capturedResult: [RemoteFeedLoader.Result] = []
        sut?.load { capturedResult.append($0) }
        
        sut = nil
        client.complete(withStatusCode: 200, data: makeItemsJSON([]))
        
        XCTAssertTrue(capturedResult.isEmpty)
    }
    
    private func makeItemsJSON(_ items: [[String:Any]]) -> Data {
        let itemsJSON = ["items":items]
        return try! JSONSerialization.data(withJSONObject: itemsJSON)
    }
    
    private func makeItem(id: UUID,
                          description: String? = nil,
                          location: String? = nil,
                          imageURL: URL)
        -> (model: FeedItem, json: [String:Any]) {
        let item = FeedItem(id: id, description: description, location: location, imageURL: imageURL)
        
        let json = ["id":id.uuidString, "description":description, "location":location, "image":imageURL.absoluteString]
            .reduce(into: [String:Any]()) { (acc, e) in
                if let value = e.value {
                    acc[e.key] = value
                }
        }
        return (item, json)
    }
    
    private func expect(_ sut: RemoteFeedLoader, toCompleteWith expectedResult:RemoteFeedLoader.Result,
                        when action: () -> Void, file: StaticString = #file, line: UInt = #line) {
        let exp = expectation(description: "Wait for load completion")
        sut.load { receivedResult in
            switch (receivedResult, expectedResult) {
            case let (.success(receivedItems), .success(expectedItems)):
                XCTAssertEqual(receivedItems, expectedItems, file: file, line: line)
            case let (.failure(receivedError as RemoteFeedLoader.Error), .failure(expectedError as RemoteFeedLoader.Error)):
                XCTAssertEqual(receivedError, expectedError, file: file, line: line)
            default:
                XCTFail("Expected result \(expectedResult) but got \(receivedResult) instead", file: file, line: line)
            }
            exp.fulfill()
        }
        action()
        wait(for: [exp], timeout: 1.0)
    }
    
    private func makeSUT(url: URL = URL(string: "https://a-url.com")!, file: StaticString = #file, line: UInt = #line) -> (sut: RemoteFeedLoader, client: HTTPClientSpy) {
        let client = HTTPClientSpy()
        let sut = RemoteFeedLoader(url: url, client: client)
        trackForMemoryLeaks(sut, file: file, line: line)
        trackForMemoryLeaks(client, file: file, line: line)
        return (sut, client)
    }
    
    private func failure(_ error: RemoteFeedLoader.Error) -> RemoteFeedLoader.Result {
        return .failure(error)
    }
        
    private class HTTPClientSpy: HTTPClient {
        var messages = [(
            url:URL,
            completion:(HTTPClientResult)->Void
            )]()
        
        var requestedURLs: [URL] {
            return messages.map {$0.url}
        }
        
        func get(from url: URL,
                 completion: @escaping (HTTPClientResult) -> Void) {
            messages.append((url, completion))
        }
        
        func complete(with error: Error, at index: Int = 0) {
            messages[index].completion(.failure(error))
        }
        
        func complete(withStatusCode code: Int, data: Data, at index: Int = 0) {
            let response = HTTPURLResponse(url: requestedURLs[index], statusCode: code, httpVersion: nil, headerFields: nil)!
            
            messages[index].completion(.success(data, response))
        }
    }
    
}

//: ***
//: *App.swift*
#if !DEBUG
class App {
    init() {
        let tests = RemoteFeedLoaderTests()
        tests.allTests = [
            tests.test_init_doesNotRequestDataFromURL,
            tests.test_load_requestsDataFromURL,
            tests.test_loadTwice_requestsDataFromURLTwice,
            tests.test_load_deliversErrorOnClientError,
            tests.test_load_deliversErrorOnNon200HTTPResponse,
            tests.test_load_deliversNoItemsOn200HTTPResponseWithEmptyJSONList,
            tests.test_load_deliversItemsOn200HTTPResponseWithJSONItems
        ]
        try? tests.run()
    }
}

let app = App()
#endif
























