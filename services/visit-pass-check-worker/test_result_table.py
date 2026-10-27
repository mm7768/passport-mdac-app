import ast
import unittest
from pathlib import Path
from playwright.sync_api import sync_playwright
import worker


HEADERS='<tr><th>Date</th><th>Time</th><th>Entry / Exit</th><th>Location</th><th>Type of Pass</th><th>Date of Pass Expiry</th></tr>'
def table(date='28/10/2026',expiry='27/11/2026',movement='ENTRY',style='',rows=True):
    return '<table id="results" style="'+style+'">'+HEADERS+('<tr><td>'+date+'</td><td>10:00</td><td>'+movement+'</td><td>TEST LOCATION</td><td>SOCIAL VISIT PASS</td><td>'+expiry+'</td></tr>' if rows else '')+'</table>'


class ResultTableTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pw=sync_playwright().start()
        cls.browser=cls.pw.chromium.launch(headless=True)
        cls.context=cls.browser.new_context()
        cls.context.route('**/*',lambda route:route.abort())
        cls.page=cls.context.new_page()
        tree=ast.parse(Path(worker.__file__).read_text(encoding='utf-8'))
        for node in ast.walk(tree):
            if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='matched_box' for t in node.targets) and isinstance(node.value,ast.Await):
                expression=ast.Expression(node.value.value.args[0]);ast.fix_missing_locations(expression)
                cls.match_js=eval(compile(expression,'worker_match_expression','eval'),{'__builtins__':{},'VISIT_PASS_TABLE_FINDER_JS':worker.VISIT_PASS_TABLE_FINDER_JS})
                break
        else:raise AssertionError('Actual Worker matcher expression not found')

    @classmethod
    def tearDownClass(cls):
        cls.context.close();cls.browser.close();cls.pw.stop()

    def found_id(self,markup):
        self.page.set_content(markup)
        return self.page.evaluate('() => {const t=('+worker.VISIT_PASS_TABLE_FINDER_JS+')();return t?t.id:null;}')

    def test_result_after_unrelated_first_table(self):
        self.assertEqual(self.found_id('<table id="search"><tr><td>Passport</td></tr></table>'+table()),'results')

    def test_misleading_line_id_does_not_hide_result(self):
        self.assertEqual(self.found_id('<table id="line"><tr><td>Form</td></tr></table>'+table()),'results')

    def test_nested_layout_table_not_selected(self):
        self.assertEqual(self.found_id('<table id="layout"><tr><td>'+table()+'</td></tr></table>'),'results')

    def test_hidden_result_not_ready(self):
        self.assertIsNone(self.found_id(table(style='display:none')))

    def test_headers_without_data_not_ready(self):
        self.assertIsNone(self.found_id(table(rows=False)))

    def test_expiry_date_cannot_match_entry_date(self):
        self.page.set_content(table(date='17/09/2026',expiry='28/10/2026'))
        self.assertIsNone(self.page.evaluate(self.match_js,worker.entry_window_candidates('2026-10-28')))

    def test_actual_entry_date_matches(self):
        self.page.set_content('<table><tr><td>Search</td></tr></table>'+table())
        self.assertIsNotNone(self.page.evaluate(self.match_js,worker.entry_window_candidates('2026-10-28')))

    def test_exit_record_cannot_match_entry(self):
        self.page.set_content(table(movement='EXIT'))
        self.assertIsNone(self.page.evaluate(self.match_js,worker.entry_window_candidates('2026-10-28')))

if __name__=='__main__':unittest.main()

