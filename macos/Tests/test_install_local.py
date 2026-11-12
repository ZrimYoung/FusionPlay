import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).parents[1] / 'scripts/install-local.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class InstallTests(unittest.TestCase):
    def test_existing_identity_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = root / 'existing'; data.mkdir()
            identity = data / 'identity.json'; identity.write_text('keep')
            with self.assertRaises(RuntimeError):
                installer.install(root, root / 'app', data)
            self.assertEqual(identity.read_text(), 'keep')
            self.assertFalse((root / 'app').exists())

    def test_corrupt_copy_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp)/'a', Path(tmp)/'b'; a.mkdir(); b.mkdir()
            (a/'identity.json').write_text('original')
            (b/'identity.json').write_text('changed')
            with self.assertRaises(RuntimeError): installer.verify_tree(a,b)
            self.assertEqual((a/'identity.json').read_text(), 'original')

    def test_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root/'a').mkdir(); (root/'b').mkdir()
            (root/'a/link').symlink_to(root/'b', target_is_directory=True)
            with self.assertRaises(RuntimeError): installer.verify_tree(root/'a',root/'b')
