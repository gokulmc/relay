import XCTest
@testable import RelayKit

final class ProcessRunningTests: XCTestCase {
    func testRunSuccessfulEchoCommand() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/bin/echo",
            arguments: ["hello"],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.stdout.contains("hello"))
    }

    func testRunMultipleArguments() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/bin/echo",
            arguments: ["foo", "bar", "baz"],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.stdout.contains("foo"))
        XCTAssertTrue(outcome.stdout.contains("bar"))
        XCTAssertTrue(outcome.stdout.contains("baz"))
    }

    func testRunFailingCommand() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/usr/bin/false",
            arguments: [],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertNotEqual(outcome.exitCode, 0)
        XCTAssertFalse(outcome.succeeded)
    }

    func testRunTrueCommand() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/usr/bin/true",
            arguments: [],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.succeeded)
    }

    func testRunWithEnvironmentVariables() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/bin/sh",
            arguments: ["-c", "echo $TEST_VAR"],
            environment: ["TEST_VAR": "test_value"],
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.stdout.contains("test_value"))
    }

    func testRunCapturesStdout() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/bin/echo",
            arguments: ["stdout message"],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.stdout.contains("stdout message"))
        XCTAssertEqual(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testRunCapturesStderr() async throws {
        let runner = FoundationProcessRunner()
        let outcome = try await runner.run(
            command: "/bin/sh",
            arguments: ["-c", "echo error message >&2"],
            environment: nil,
            workingDirectory: nil
        )
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertTrue(outcome.stderr.contains("error message"))
    }

    func testProcessOutcomeEquatable() {
        let outcome1 = ProcessOutcome(exitCode: 0, stdout: "out", stderr: "err")
        let outcome2 = ProcessOutcome(exitCode: 0, stdout: "out", stderr: "err")
        let outcome3 = ProcessOutcome(exitCode: 1, stdout: "out", stderr: "err")

        XCTAssertEqual(outcome1, outcome2)
        XCTAssertNotEqual(outcome1, outcome3)
    }

    func testProcessOutcomeSucceeded() {
        let successOutcome = ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
        let failOutcome = ProcessOutcome(exitCode: 1, stdout: "", stderr: "")

        XCTAssertTrue(successOutcome.succeeded)
        XCTAssertFalse(failOutcome.succeeded)
    }
}
