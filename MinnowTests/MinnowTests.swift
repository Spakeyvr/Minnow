//
//  MinnowTests.swift
//  MinnowTests
//
//  Created by Nevio on 10/24/25.
//
//  Root of the MinnowTests suite. The individual @Test methods live in the
//  MinnowTests+Topic.swift extension files, and shared mocks live in
//  MinnowTestHelpers.swift.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
import WebKit
import UIKit
import FoundationModels
@testable import Minnow

@MainActor
@Suite(.serialized)
struct MinnowTests {
    let testEnvironment = ChatTestEnvironment()
}
