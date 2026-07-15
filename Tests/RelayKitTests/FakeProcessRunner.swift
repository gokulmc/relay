import Foundation
@testable import RelayKit

actor FakeProcessRunner: ProcessRunning {
    struct Call: Equatable {
        let command: String
        let arguments: [String]
    }

    private var scripted: [ProcessOutcome] = []
    private(set) var calls: [Call] = []

    func enqueue(_ outcome: ProcessOutcome) {
        scripted.append(outcome)
    }

    func enqueueSuccess(stdout: String = "", stderr: String = "") {
        scripted.append(ProcessOutcome(exitCode: 0, stdout: stdout, stderr: stderr))
    }

    func enqueueFailure(exitCode: Int32 = 1, stderr: String) {
        scripted.append(ProcessOutcome(exitCode: exitCode, stdout: "", stderr: stderr))
    }

    func run(
        command: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: String?
    ) async throws -> ProcessOutcome {
        calls.append(Call(command: command, arguments: arguments))
        if scripted.isEmpty {
            return ProcessOutcome(exitCode: 0, stdout: "", stderr: "")
        }
        return scripted.removeFirst()
    }
}
