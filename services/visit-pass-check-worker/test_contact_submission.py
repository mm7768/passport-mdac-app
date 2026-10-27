import asyncio
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import parse_qs
from playwright.async_api import async_playwright
from worker import prepare_visit_contact_submission


class ContactSubmissionTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body=cls.markup.encode();self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers();self.wfile.write(body)
            def do_POST(self):
                cls.received=parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
                self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(b'{"ok":true}')
            def log_message(self,*args):pass
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()

    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close();cls.thread.join()

    async def run_submission(self,switch_to,expected='86'):
        type(self).received={}
        type(self).markup='''<form method="post" action="/query">
          <input id="passNo" name="passNo" value="SYNTHETIC">
          <select id="nationality" name="nationality"><option value="TWN">Taiwan</option><option value="CHN">China</option></select>
          <select id="regCd" name="regCd"><option value="886">Taiwan</option><option value="86">China</option><option value="60">Malaysia</option></select>
          <input id="mobile" name="mobile" value="11111"><input id="pinKeyId" name="pinKey" value="TEST-PIN">
          <button type="submit" id="submit" onclick="'''+("document.getElementById('regCd').value='"+switch_to+"';document.getElementById('mobile').value='99999';" if switch_to else '')+'''">Query</button></form>'''
        async with async_playwright() as pw:
            browser=await pw.chromium.launch(headless=True);page=await browser.new_page()
            await page.goto('http://127.0.0.1:'+str(self.server.server_port)+'/')
            state=await prepare_visit_contact_submission(page,{'passport_number':'SYNTHETIC','nationality':'TWN','pin_value':'TEST-PIN','region_code':expected,'mobile':'13800000000'})
            self.assertEqual(await page.input_value('#regCd'),expected)
            self.assertEqual(await page.input_value('#nationality'),'TWN')
            async with page.expect_navigation():await page.click('#submit')
            await browser.close()
        return state,type(self).received

    async def test_late_taiwan_default_is_corrected_in_actual_post(self):
        state,posted=await self.run_submission('886')
        self.assertEqual(posted['regCd'],['86']);self.assertEqual(posted['mobile'],['13800000000'])
        self.assertEqual(posted['nationality'],['TWN']);self.assertEqual(posted['pinKey'],['TEST-PIN'])
        self.assertTrue(state['request_verified']);self.assertTrue(state['region_corrected_at_request'])

    async def test_already_correct_contact_is_preserved(self):
        state,posted=await self.run_submission(None)
        self.assertEqual(posted['regCd'],['86']);self.assertFalse(state['region_corrected_at_request'])

    async def test_other_explicit_country_code_is_respected(self):
        state,posted=await self.run_submission('886','60')
        self.assertEqual(posted['regCd'],['60']);self.assertEqual(posted['nationality'],['TWN'])
        self.assertEqual(state['submitted_region_code'],'60')

if __name__=='__main__':unittest.main()

