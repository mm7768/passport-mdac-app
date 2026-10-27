import unittest
from email.message import EmailMessage
from worker import parse_message


class PinTableLayoutTests(unittest.TestCase):
    def parse(self, rows):
        message = EmailMessage()
        message.set_content('<table>'+rows+'</table><p>Thank you for registering</p>',subtype='html')
        return parse_message(message.as_bytes()).pin

    def test_official_indented_three_cell_layout(self):
        self.assertEqual(self.parse('<tr><td>\r\n  PIN  \r\n</td><td>\r\n : \r\n</td><td>\r\n  Ab12Cd34 \r\n</td></tr>'),'Ab12Cd34')

    def test_inner_spaces_preserved(self):
        self.assertEqual(self.parse('<tr><td>PIN</td><td>:</td><td>  Ab12  Cd34  </td></tr>'),'Ab12  Cd34')

    def test_empty_pin_does_not_read_next_row(self):
        self.assertIsNone(self.parse('<tr><td>PIN</td><td>:</td><td> </td></tr><tr><td>Thank you for registering</td></tr>'))

    def test_conflicting_rows_not_guessed(self):
        self.assertIsNone(self.parse('<tr><td>PIN</td><td>:</td><td>Ab12Cd34</td></tr><tr><td>PIN</td><td>:</td><td>Zz98Yy76</td></tr>'))

    def test_unrelated_row_ignored(self):
        self.assertIsNone(self.parse('<tr><td>Passport No.</td><td>:</td><td>AB123456</td></tr>'))

    def test_nested_formatting_in_value(self):
        self.assertEqual(self.parse('<tr><td>PIN</td><td>:</td><td><b>Ab12Cd34</b></td></tr>'),'Ab12Cd34')

    def test_two_cell_layout(self):
        self.assertEqual(self.parse('<tr><td>PIN :</td><td>Ab12Cd34</td></tr>'),'Ab12Cd34')

if __name__=='__main__':
    unittest.main()

