"""The engine compiler must reject an unqualified product checkout first."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location(
    'source_engine_builder', Path(__file__).resolve().parents[1] / 'ci/build_source_engine.py')
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class SourceEnginePolicyTests(unittest.TestCase):
    def test_unqualified_product_is_rejected_before_fetch_or_artifact_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project, output = root / 'product', root / 'artifact'
            project.mkdir()
            with mock.patch.object(engine.platform, 'system', return_value='Darwin'), \
                 mock.patch.object(engine, 'validate_checkout', side_effect=RuntimeError('unqualified engine policy')), \
                 mock.patch.object(engine, 'run') as run, \
                 mock.patch.object(engine, 'compile_engine') as compile_engine:
                with self.assertRaisesRegex(RuntimeError, 'unqualified engine policy'):
                    engine.build(project, output)
                run.assert_not_called()
                compile_engine.assert_not_called()
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
