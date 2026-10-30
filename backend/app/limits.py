import asyncio
import hashlib
import time
from contextlib import asynccontextmanager
from uuid import uuid4

import anyio
from redis.asyncio import Redis

from .config import Settings
from .errors import ApiError


class MemoryLimiter:
    """Development only: per-process counters, lost on restart."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._users: dict = {}
        self._lock = asyncio.Lock()

    async def acquire(self, uid: str) -> str:
        async with self._lock:
            now = time.time()
            day = int(now // 86400)
            # Bound memory used by otherwise valid but high-cardinality identities.
            if uid not in self._users and len(self._users) >= 10_000:
                self._users = {k: v for k, v in self._users.items()
                               if v["day"] == day or v["active"]}
                if len(self._users) >= 10_000:
                    raise ApiError(503, "quota_unavailable", "Quota service is busy.", True)
            state = self._users.setdefault(uid, {"day": day, "count": 0,
                                                 "recent": [], "active": set()})
            if state["day"] != day:
                state["day"], state["count"] = day, 0
            state["recent"] = [t for t in state["recent"] if t > now - 60]
            if (len(state["recent"]) >= self.settings.requests_per_minute
                    or state["count"] >= self.settings.requests_per_day
                    or len(state["active"]) >= self.settings.max_concurrent_requests):
                raise ApiError(429, "quota_exceeded", "AI request limit reached. Try again later.", True)
            lease = uuid4().hex
            state["recent"].append(now)
            state["count"] += 1
            state["active"].add(lease)
            return lease

    async def release(self, uid: str, lease: str):
        async with self._lock:
            if uid in self._users:
                self._users[uid]["active"].discard(lease)

    async def close(self):
        pass


# Atomic shared admission: rolling minute, UTC daily request quota, and expiring
# concurrency leases. All keys share a Redis Cluster hash slot per UID.
ADMIT = """
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local day = math.floor(tonumber(t[1]) / 86400)
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', now - 60000)
redis.call('ZREMRANGEBYSCORE', KEYS[3], '-inf', now)
local count = 0
if tonumber(redis.call('HGET', KEYS[2], 'day')) == day then
  count = tonumber(redis.call('HGET', KEYS[2], 'count') or '0')
end
if redis.call('ZCARD', KEYS[1]) >= tonumber(ARGV[1]) or
   count >= tonumber(ARGV[2]) or
   redis.call('ZCARD', KEYS[3]) >= tonumber(ARGV[3]) then return 0 end
redis.call('ZADD', KEYS[1], now, ARGV[5])
redis.call('EXPIRE', KEYS[1], 120)
redis.call('HSET', KEYS[2], 'day', day, 'count', count + 1)
redis.call('EXPIRE', KEYS[2], 172800)
redis.call('ZADD', KEYS[3], now + tonumber(ARGV[4]), ARGV[5])
redis.call('PEXPIRE', KEYS[3], tonumber(ARGV[4]) + 1000)
return 1
"""


class RedisLimiter:
    def __init__(self, settings: Settings, client=None):
        self.settings = settings
        self.client = client or Redis.from_url(settings.redis_url.get_secret_value(),
                                               socket_connect_timeout=2, socket_timeout=2)

    def keys(self, uid: str):
        tag = hashlib.sha256(uid.encode()).hexdigest()
        return [f"aimind:{{{tag}}}:{suffix}" for suffix in ("minute", "day", "active")]

    async def acquire(self, uid: str) -> str:
        lease = uuid4().hex
        lifetime = int(max(self.settings.stream_timeout_seconds,
                           self.settings.request_timeout_seconds) * 1000) + 30_000
        try:
            accepted = await self.client.eval(
                ADMIT, 3, *self.keys(uid), self.settings.requests_per_minute,
                self.settings.requests_per_day, self.settings.max_concurrent_requests,
                lifetime, lease,
            )
        except Exception:
            raise ApiError(503, "quota_unavailable", "Quota service is unavailable.", True) from None
        if not accepted:
            raise ApiError(429, "quota_exceeded", "AI request limit reached. Try again later.", True)
        return lease

    async def release(self, uid: str, lease: str):
        try:
            await self.client.zrem(self.keys(uid)[2], lease)
        except Exception:
            # A failed release remains charged until the bounded lease expires.
            pass

    async def close(self):
        await self.client.aclose()


@asynccontextmanager
async def admission(limiter, uid: str):
    lease = await limiter.acquire(uid)
    try:
        yield
    finally:
        # Starlette cancels streaming generators on disconnect. Release even then.
        with anyio.CancelScope(shield=True):
            await limiter.release(uid, lease)
