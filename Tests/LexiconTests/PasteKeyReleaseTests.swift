import Testing
import TestSupport
@testable import AppText

@MainActor @Test(.timeLimit(.minutes(1)))
func releasedKeysReturnWithoutSleeping() async {
    let clock = TestClock()
    let result = await Paster.waitForKeysReleased(clock: clock, keysDown: { false })

    #expect(result.waited == .zero)
    #expect(result.stillDown == false)
    #expect(clock.sleepers == 0)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func heldKeysAreRecheckedAfterOnePoll() async {
    let clock = TestClock()
    var down = true
    let wait = Task {
        await Paster.waitForKeysReleased(clock: clock, keysDown: { down })
    }

    await clock.waitForSleepers(1)
    down = false
    await clock.advance(by: .milliseconds(10))
    let result = await wait.value

    #expect(result.waited == .milliseconds(10))
    #expect(result.stillDown == false)
    #expect(clock.sleepers == 0)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func heldKeysStopWaitingAtTheBoundedDeadline() async {
    let clock = TestClock()
    let wait = Task {
        await Paster.waitForKeysReleased(clock: clock, keysDown: { true })
    }

    for _ in 0..<100 {
        await clock.waitForSleepers(1)
        await clock.advance(by: .milliseconds(10))
    }
    let result = await wait.value

    #expect(result.waited == .seconds(1))
    #expect(result.stillDown)
    #expect(clock.sleepers == 0)
}
