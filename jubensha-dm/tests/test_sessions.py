"""Run from jubensha-dm: python -m unittest discover -s tests -p test_sessions.py"""
import json
import unittest
from types import SimpleNamespace

from starlette.requests import Request
from jubensha.engine import Bus
from jubensha.server import create_app
from jubensha.state import GameState, Player


class SessionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.state = GameState(script_title="test")
        self.player = Player(char_id="a", name="A", token="old")
        self.state.players["a"] = self.player
        self.bus = Bus()
        game = SimpleNamespace(state=self.state, bus=self.bus,
                               view_player=lambda cid: {"private": "secret"},
                               view_admin=lambda: {}, view_public=lambda: {})
        self.app = create_app(game)

    async def call(self, path, query=b"", payload=None):
        endpoint = next(r.endpoint for r in self.app.routes if r.path == path)
        async def receive():
            return {"type": "http.request", "body": json.dumps(payload).encode()}
        return await endpoint(Request({"type": "http", "method": "POST",
                                      "path": path, "query_string": query, "headers": []}, receive))

    async def stream(self):
        response = await self.call("/api/events", b"role=player&token=old")
        return response.body_iterator

    async def test_reclaimed_character_revokes_old_stream(self):
        stream = await self.stream()
        self.assertIn('"view"', await anext(stream))
        self.player.token = "replacement"
        self.bus.refresh()
        self.assertIn('"kicked"', await anext(stream))
        with self.assertRaises(StopAsyncIteration):
            await anext(stream)
        self.assertEqual(self.bus.subs, [])

    async def test_queued_private_event_cannot_reach_revoked_session(self):
        stream = await self.stream()
        await anext(stream)
        self.bus.send({"type": "private", "text": "new owner's secret"})
        self.player.token = "replacement"
        self.assertIn('"kicked"', await anext(stream))
        await stream.aclose()
        self.assertEqual(self.bus.subs, [])

    async def test_revoked_before_first_view(self):
        stream = await self.stream()
        self.player.claimable = True
        self.assertIn('"kicked"', await anext(stream))
        await stream.aclose()

    async def test_valid_session_refresh_and_disconnect(self):
        stream = await self.stream()
        self.assertIn('"view"', await anext(stream))
        self.bus.refresh()
        self.assertIn('"view"', await anext(stream))
        await stream.aclose()
        self.assertEqual(self.bus.subs, [])

    async def test_released_token_and_non_object_body(self):
        self.player.claimable = True
        self.assertIsNone(self.state.player_by_token("old"))
        for payload in ([], None, "invalid", {"token": "old"}):
            response = await self.call("/api/me", payload=payload)
            self.assertEqual(json.loads(response.body), {"ok": False, "code": 401})


if __name__ == "__main__":
    unittest.main()
