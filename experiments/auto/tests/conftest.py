import os
import sys

AUTO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if AUTO_ROOT not in sys.path:
    sys.path.insert(0, AUTO_ROOT)

import torch  # noqa: E402

torch.set_num_threads(2)
