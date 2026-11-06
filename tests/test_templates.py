import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("build_templates", str(ROOT / "bin" / "build-templates.py"))
spec = importlib.util.spec_from_loader("build_templates", loader)
build = importlib.util.module_from_spec(spec)
loader.exec_module(build)


class TemplateTests(unittest.TestCase):
    def test_templates_match_instructions(self):
        for out, (shape, src) in build.TEMPLATES.items():
            with self.subTest(template=out.name):
                self.assertEqual(out.read_text(encoding="utf-8"), build.render(shape, src),
                                 "run bin/build-templates.py after editing the instructions")


if __name__ == "__main__":
    unittest.main()
