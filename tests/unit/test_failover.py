"""The assistant switches to a fallback model when the main one is busy."""

import pytest
from langchain_core.messages import AIMessageChunk

from kestrel.agent import Failover


class Model:
    def __init__(self, name, fail=False, fail_after_first_chunk=False):
        self.name, self.fail, self.fail_late, self.calls = name, fail, fail_after_first_chunk, 0

    def invoke(self, messages):
        self.calls += 1
        if self.fail:
            raise RuntimeError("503 UNAVAILABLE")
        return AIMessageChunk(content=self.name)

    def stream(self, messages):
        self.calls += 1
        if self.fail:
            raise RuntimeError("503 UNAVAILABLE")
        yield AIMessageChunk(content=self.name)
        if self.fail_late:
            raise RuntimeError("connection reset")


def test_busy_model_falls_back_and_is_skipped_until_the_cooldown_ends():
    busy, lite = Model("busy", fail=True), Model("lite")
    llm = Failover([busy, lite], cooldown_s=300)
    assert llm.invoke([]).content == "lite"
    assert [c.content for c in llm.stream([])] == ["lite"]
    assert busy.calls == 1  # not tried again inside the cooldown
    llm._skip_until[0] = 0  # cooldown over
    busy.fail = False
    assert llm.invoke([]).content == "busy"


def test_every_model_failing_raises_the_last_error():
    llm = Failover([Model("a", fail=True), Model("b", fail=True)])
    with pytest.raises(RuntimeError):
        llm.invoke([])
    with pytest.raises(RuntimeError):  # all in cooldown: still tries them all
        list(llm.stream([]))


def test_a_stream_that_breaks_mid_reply_is_not_restarted_on_another_model():
    lite = Model("lite")
    llm = Failover([Model("main", fail_after_first_chunk=True), lite])
    with pytest.raises(RuntimeError):
        list(llm.stream([]))
    assert lite.calls == 0
