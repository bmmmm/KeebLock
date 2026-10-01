"""Makes the top-level scripts importable as plain modules.

scripts/*.py are standalone CLI scripts, not a package (no __init__.py).
Adding the scripts/ directory to sys.path lets tests `import fetch_codeword_data`
etc. directly and instantiate their classes/functions without running main().
"""

from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
