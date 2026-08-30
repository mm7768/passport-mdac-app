import unittest

from azure_ocr_worker import (
    content_type_for_path,
    parse_azure_result,
)


class AzureResultParsingTests(unittest.TestCase):
    def test_passport_fields_are_normalized(self):
        raw = {
            "analyzeResult": {
                "documents": [
                    {
                        "docType": "passport",
                        "fields": {
                            "FirstName": {"valueString": "LEE SHU" , "confidence": 0.99},
                            "LastName": {"valueString": "FEN", "confidence": 0.98},
                            "DocumentNumber": {"valueString": "EJ40890", "confidence": 0.99},
                            "DateOfBirth": {"valueDate": "1989-07-14", "confidence": 0.97},
                            "DateOfExpiration": {"valueDate": "2032-10-26", "confidence": 0.98},
                            "Nationality": {"valueCountryRegion": "CHN", "confidence": 0.94},
                            "Sex": {"valueString": "F", "confidence": 0.96},
                            "MachineReadableZone": {"content": "P<CHNFEN<<LEE<SHU"},
                        },
                    }
                ]
            }
        }

        extracted, confidence, status = parse_azure_result(raw)

        self.assertEqual(status, "READY_TO_CREATE")
        self.assertEqual(extracted["full_name"], "FEN LEE SHU")
        self.assertEqual(extracted["passport_number"], "EJ40890")
        self.assertEqual(extracted["date_of_birth"], "1989-07-14")
        self.assertEqual(extracted["passport_expiry_date"], "2032-10-26")
        self.assertEqual(extracted["nationality"], "CHN")
        self.assertEqual(extracted["gender"], "女")
        self.assertTrue(extracted["mrz"])
        self.assertIsNotNone(confidence)
        self.assertGreater(confidence, 0.95)

    def test_passport_name_uses_surname_then_given_names(self):
        raw = {
            "analyzeResult": {
                "documents": [
                    {
                        "docType": "passport",
                        "fields": {
                            "FirstName": {"valueString": "XISHUN,", "confidence": 0.99},
                            "LastName": {"valueString": "LI", "confidence": 0.99},
                            "DocumentNumber": {"valueString": "TEST123", "confidence": 0.99},
                            "DateOfBirth": {"valueDate": "1990-01-02", "confidence": 0.99},
                            "DateOfExpiration": {"valueDate": "2030-01-02", "confidence": 0.99},
                            "Nationality": {"valueCountryRegion": "CHN", "confidence": 0.99},
                            "Sex": {"valueString": "M", "confidence": 0.99},
                            "MachineReadableZone": {"content": "P<CHNLI<<XISHUN<<<<<<<<<<<<<<<<<<<<<<<<<<<<"},
                        },
                    }
                ]
            }
        }

        extracted, _, status = parse_azure_result(raw)

        self.assertEqual(status, "READY_TO_CREATE")
        self.assertEqual(extracted["full_name"], "LI XISHUN")

    def test_missing_critical_field_requires_review(self):
        raw = {
            "analyzeResult": {
                "documents": [
                    {
                        "docType": "passport",
                        "fields": {
                            "FirstName": {"valueString": "LEE"},
                            "LastName": {"valueString": "FEN"},
                            "DocumentNumber": {"valueString": "EJ40890"},
                            "DateOfBirth": {"valueDate": "1989-07-14"},
                            "DateOfExpiration": {"valueDate": "2032-10-26"},
                            "Nationality": {"valueCountryRegion": "CHN"},
                            "Sex": {"valueString": "X"},
                        },
                    }
                ]
            }
        }

        extracted, _, status = parse_azure_result(raw)

        self.assertEqual(status, "REVIEW_REQUIRED")
        self.assertEqual(extracted["gender"], "")

    def test_invalid_dates_require_review(self):
        raw = {
            "analyzeResult": {
                "documents": [
                    {
                        "docType": "passport",
                        "fields": {
                            "FirstName": {"valueString": "LEE"},
                            "LastName": {"valueString": "FEN"},
                            "DocumentNumber": {"valueString": "EJ40890"},
                            "DateOfBirth": {"valueDate": "31/02/1989"},
                            "DateOfExpiration": {"valueDate": "2032-10-26"},
                            "Nationality": {"valueCountryRegion": "CHN"},
                            "Sex": {"valueString": "F"},
                        },
                    }
                ]
            }
        }

        extracted, _, status = parse_azure_result(raw)

        self.assertEqual(status, "REVIEW_REQUIRED")
        self.assertEqual(extracted["date_of_birth"], "")


class FileTypeTests(unittest.TestCase):
    def test_supported_file_types(self):
        self.assertEqual(content_type_for_path("passport.pdf"), "application/pdf")
        self.assertEqual(content_type_for_path("passport.png"), "image/png")
        self.assertEqual(content_type_for_path("passport.jpg"), "image/jpeg")
        self.assertEqual(content_type_for_path("passport.unknown"), "application/octet-stream")


if __name__ == "__main__":
    unittest.main()
