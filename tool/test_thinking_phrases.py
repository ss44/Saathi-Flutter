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
    def test_counts_safety_and_normalized_uniqueness(self):
        source = collection('importedThinkingPhrases')
        excluded = collection('excludedThinkingPhrases')
        new = collection('newThinkingPhrases')
        self.assertEqual(len(source), 225)
        self.assertEqual(len(new), 200)
        # Exact source ordering/copy and exact supplied new collection, portable
        # even when the source checkout and input scratch file are absent.
        for lines, digest in [(source, '2653da6f75c825a69cd346e7e7a9aeaf16d18d81c2a5334b76b6c11fcfdc0d86'), (new, '6c5abb337260673606b9632ccbfb81f9c4a4119decdc1241ae25d15c69b9b1e2')]:
            self.assertEqual(hashlib.sha256(json.dumps(lines, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest(), digest)
        self.assertEqual(len(excluded), 75)
        self.assertTrue(set(excluded) <= set(source))
        visible = [s for s in source if s not in excluded] + new
        self.assertEqual(len(visible), len({normalized(s) for s in visible}))
        for phrase in ['Deleting system32... just kidding', 'Corrupted data', 'Blue screen of death', 'Kernel panic', 'Disconnecting', 'Checking for updates', 'Code writing']:
            self.assertIn(phrase, excluded)
        supplied = Path('/opt/data/cache/scratch/saathi-thinking-new-lines.json')
        if supplied.exists():
            self.assertEqual(new, json.loads(supplied.read_text()))

if __name__ == '__main__':
    unittest.main()
