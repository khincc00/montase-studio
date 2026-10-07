//
//  KHCutProUITests.swift
//  KHCutProUITests
//
//  Created by taufiq sholikhin on 05/10/26.
//

import XCTest

final class KHCutProUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testProfessionalDemoProject() throws {
        let workspace = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mediaFolder = workspace.appendingPathComponent("DemoProject/Media")
        let app = XCUIApplication()
        app.launchArguments = ["--demo-project", mediaFolder.path]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["coast-dawn"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["CINEMATIC GRADE"].exists)
        XCTAssertTrue(app.staticTexts["ISLAND LIGHT"].exists)
        XCTAssertTrue(app.staticTexts["Island Score"].exists)
        XCTAssertTrue(app.staticTexts["Forest Ambience"].exists)
        Thread.sleep(forTimeInterval: 3)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "KHCutPro — Island Light layered timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
