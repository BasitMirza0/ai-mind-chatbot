"""Regression for the cancelled disconnect watcher that blocked pre-SSE replies."""
import asyncio

import pytest
from starlette.requests import Request

from app.errors import ApiError
from app.main import while_connected


@pytest.mark.asyncio
@pytest.mark.parametrize("fails", [False, True], ids=["success", "provider-error"])
@pytest.mark.parametrize("delay", [0, .001], ids=["immediate", "delayed"])
async def test_finished_work_does_not_wait_for_disconnect(fails, delay):
    # Use Starlette's real Request and a connected ASGI receive channel, not an
    # is_disconnected stub that would hide its self-cancelling AnyIO scope.
    baseline = asyncio.all_tasks()
    release = asyncio.Event()

    async def receive():
        await release.wait()
        return {"type": "http.disconnect"}

    async def work():
        if delay:
            await asyncio.sleep(delay)
        if fails:
            raise ApiError(503, "provider_not_configured", "AI is not configured on the backend yet.")
        return ("delta", "Hello")

    task = asyncio.create_task(while_connected(Request({"type": "http"}, receive), work()))
    try:
        done, _ = await asyncio.wait({task}, timeout=1)
        assert task in done, "Completed work is stuck waiting for the disconnect watcher"
        if fails:
            with pytest.raises(ApiError) as error:
                task.result()
            assert error.value.code == "provider_not_configured"
        else:
            assert task.result() == ("delta", "Hello")
    finally:
        # A regression must fail within a bound rather than hang test teardown.
        # Releasing the channel also lets the old polling implementation unwind.
        release.set()
        await asyncio.wait({task}, timeout=1)
        if task.done():
            await asyncio.gather(task, return_exceptions=True)
        else:
            task.cancel()
    await asyncio.sleep(0)
    assert not (asyncio.all_tasks() - baseline), "Disconnect helper leaked an asyncio task"


@pytest.mark.asyncio
async def test_request_cancellation_joins_work_and_receiver():
    baseline = asyncio.all_tasks()
    receiving = asyncio.Event()
    work_started = asyncio.Event()
    work_stopped = asyncio.Event()
    receive_stopped = asyncio.Event()
    release = asyncio.Event()

    async def receive():
        receiving.set()
        try:
            await release.wait()
            return {"type": "http.disconnect"}
        finally:
            receive_stopped.set()

    async def work():
        work_started.set()
        try:
            await asyncio.sleep(30)
        finally:
            work_stopped.set()

    task = asyncio.create_task(while_connected(Request({"type": "http"}, receive), work()))
    await asyncio.wait_for(receiving.wait(), 1)
    await asyncio.wait_for(work_started.wait(), 1)
    task.cancel()
    try:
        done, _ = await asyncio.wait({task}, timeout=1)
        assert task in done, "Request cancellation did not finish helper cleanup"
        with pytest.raises(asyncio.CancelledError):
            task.result()
        assert work_stopped.is_set()
        assert receive_stopped.is_set()
    finally:
        release.set()
        await asyncio.wait({task}, timeout=1)
        if task.done():
            await asyncio.gather(task, return_exceptions=True)
        else:
            task.cancel()
    assert not (asyncio.all_tasks() - baseline)
