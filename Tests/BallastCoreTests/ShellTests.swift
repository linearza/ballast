import Foundation
import Testing
@testable import BallastCore

@Suite struct ShellTests {
    @Test func quotesSpacesAndQuotes() {
        #expect(shellQuote("/a b/it's") == "'/a b/it'\\''s'")
    }

    @Test func leavesPlainWordsAlone() {
        #expect(shellQuote("v16.0.0") == "v16.0.0")
        #expect(shellQuote("/opt/homebrew/var/log") == "/opt/homebrew/var/log")
        #expect(shellQuote("") == "''")
    }

    @Test func runsEcho() async {
        let r = await ProcessRunner().run(["/bin/echo", "hi"], timeout: .seconds(5))
        #expect(r.stdout == "hi\n")
        #expect(r.ok)
    }

    @Test func findsToolsOnLoginPath() async {
        let r = await ProcessRunner().run(["echo", "hi"], timeout: .seconds(5))
        #expect(r.ok)
        #expect(await ProcessRunner().which("ls")?.path == "/bin/ls")
    }

    @Test func missingToolFails() async {
        let r = await ProcessRunner().run(["definitely-not-a-tool"], timeout: .seconds(5))
        #expect(!r.ok)
        #expect(!r.stderr.isEmpty)
        #expect(await ProcessRunner().which("definitely-not-a-tool") == nil)
    }

    @Test func reportsExitStatusAndStderr() async {
        let r = await ProcessRunner().shell("echo oops >&2; exit 3", timeout: .seconds(10))
        #expect(r.status == 3)
        #expect(r.stderr == "oops\n")
    }

    @Test func timesOut() async {
        let started = Date()
        let r = await ProcessRunner().shell("sleep 5", timeout: .milliseconds(200))
        #expect(!r.ok)
        #expect(r.stderr.contains("timed out"))
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func largeOutputDoesNotDeadlock() async {
        let r = await ProcessRunner().run(["/usr/bin/yes"], timeout: .milliseconds(300))
        #expect(r.stdout.count > 65536)
    }

    @Test func liveEnvironmentUsesRealHome() {
        let env = Environment.live(projectRoots: [])
        #expect(env.home == FileManager.default.homeDirectoryForCurrentUser)
        #expect(env.applications.first?.path == "/Applications")
    }
}
