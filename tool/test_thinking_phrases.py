"""Validate static UI copy with full Unicode normalization, no dependencies."""
import hashlib
import json
from pathlib import Path
import re
import unittest
import unicodedata

ROOT = Path(__file__).resolve().parents[1]

def collection(name):
    text = (ROOT / 'lib/ui/thinking_phrases.dart').read_text()
    return json.loads(re.search(r'const ' + name + r' = (\[.*?\]);', text, re.S).group(1))

def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).casefold() if c.isalnum())

class ThinkingCopyTest(unittest.TestCase):
    def test_original_source_copy_and_new_phrase_count(self):
        source = collection('importedThinkingPhrases')
        new = collection('newThinkingPhrases')
        self.assertEqual(len(source), 225)
        self.assertEqual(len(new), 200)
        source_json = json.dumps(source, ensure_ascii=False, separators=(',', ':'))
        self.assertEqual(
            hashlib.sha256(source_json.encode()).hexdigest(),
            '2653da6f75c825a69cd346e7e7a9aeaf16d18d81c2a5334b76b6c11fcfdc0d86',
        )
        source_keys = {normalized(phrase) for phrase in source}
        new_keys = {normalized(phrase) for phrase in new}
        self.assertNotIn('', new_keys)
        self.assertEqual(len(new), len(new_keys))
        self.assertTrue(source_keys.isdisjoint(new_keys))

if __name__ == '__main__':
    unittest.main()
