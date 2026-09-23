"""The `UNSET` sentinel — "caller didn't provide this field", as distinct from an
explicit `None`, which means "clear this field".

Every `update()` here started with a `None = leave unchanged` contract. That is
fine while updates are additive, but it makes a **nullable column impossible to
clear**: passing `goal_id=None` to unlink an assignment from its goal is
indistinguishable from omitting `goal_id`, so nothing could ever be unlinked,
unscheduled, or reset to inherit. The field simply had no "off".

The contract now:

* nullable columns  — `UNSET` = unchanged · `None` = set SQL NULL · value = set
* non-null columns  — `None` = unchanged (unchanged from before; there is no
  meaningful "clear" for a title or a status, and text fields clear with "")

Callers that build kwargs dynamically (REST) should pass only the fields the
client actually sent — FastAPI/pydantic: `body.model_dump(exclude_unset=True)`.
The MCP surface keeps its `None = unchanged` contract (an agent has no clean way
to express an explicit JSON null through a typed tool signature), so its tools
filter Nones out before calling core.
"""

from __future__ import annotations

from enum import Enum
from typing import Literal


class _Unset(Enum):
    """Single-member enum: the idiom mypy narrows precisely in `X | None | Unset`."""

    token = 0

    def __repr__(self) -> str:  # pragma: no cover - debug aid only
        return "UNSET"


UNSET = _Unset.token
Unset = Literal[_Unset.token]
