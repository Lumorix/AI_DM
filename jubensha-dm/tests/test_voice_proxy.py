import json
import unittest
from unittest.mock import patch
from starlette.requests import Request
from jubensha.voice_proxy import voice_proxy


def request(host='127.0.0.1', payload=None, origin=None):
    headers=[(b'host',b'127.0.0.1:8000')]
    if origin:
        headers.append((b'origin',origin.encode()))
    async def receive():
        return {'type':'http.request','body':json.dumps(payload).encode(),'more_body':False}
    return Request({'type':'http','scheme':'http','path':'/api/voice/speech','query_string':b'',
                    'method':'POST','headers':headers,'client':(host,1234),'server':('127.0.0.1',8000)},receive)


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_rejects_remote_and_cross_origin(self):
        self.assertEqual((await voice_proxy(request(host='192.168.1.5'))).status_code,403)
        self.assertEqual((await voice_proxy(request(origin='https://example.com'))).status_code,403)

    async def test_rejects_invalid_text(self):
        for body in ([], {'text':''}, {'text':'x'*121}):
            self.assertEqual((await voice_proxy(request(payload=body))).status_code,400)

    async def test_unavailable_service_is_503(self):
        with patch('jubensha.voice_proxy.urllib.request.build_opener', side_effect=OSError('offline')):
            response=await voice_proxy(request(payload={'text':'你好'}))
        self.assertEqual(response.status_code,503)
        self.assertIn('error',json.loads(response.body))

    async def test_success_forwards_wav(self):
        from email.message import Message
        from unittest.mock import MagicMock
        response=MagicMock();response.status=200
        response.headers=Message();response.headers['Content-Type']='audio/wav'
        response.read.return_value=b'RIFF-test'
        response.__enter__.return_value=response
        with patch('jubensha.voice_proxy.urllib.request.build_opener') as opener:
            opener.return_value.open.return_value=response
            result=await voice_proxy(request(payload={'text':'你好'}))
        self.assertEqual(result.status_code,200)
        self.assertEqual(result.body,b'RIFF-test')
