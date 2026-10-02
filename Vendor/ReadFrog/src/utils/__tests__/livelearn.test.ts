import { TextEncoder as NativeTextEncoder } from "node:util"
import { beforeAll, describe, expect, it, vi } from "vitest"
import { liveLearnSelectionURL } from "../livelearn"

describe("LiveLearn public selection handoff", () => {
  // Upstream's jsdom shim maps code points into single bytes; size limits need real UTF-8.
  beforeAll(() => vi.stubGlobal("TextEncoder", NativeTextEncoder))
  it("round-trips multilingual content without turning it into URL commands", () => {
    const text = "A&B + 中文\n%2F ?action=reset"
    const url = new URL(liveLearnSelectionURL(text)!)
    expect(url.protocol).toBe("livelearn:")
    expect(url.hostname).toBe("translate")
    expect([...url.searchParams]).toEqual([["text", text]])
  })
  it("rejects empty input and enforces the app's UTF-8 size bound", () => {
    expect(liveLearnSelectionURL(" \n")).toBeNull()
    expect(liveLearnSelectionURL("中".repeat(90_000))).toBeNull()
    expect(liveLearnSelectionURL("x".repeat(262_144))).not.toBeNull()
    expect(liveLearnSelectionURL("x".repeat(262_145))).toBeNull()
  })
})
