# Python Code Generation & Architecture Standards

Always adhere strictly to the following standards when writing, modifying, or refactoring Python code.

## 1. Style & Formatting (Google Python Style Guide)
- Follow the [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html) strictly.
- 4-space indentation, 80-character line limit.
- `from __future__ import annotations` at the top of every file.
- Naming conventions: `snake_case` for functions/variables/modules, `PascalCase` for classes, `CAPITAL_SNAKE_CASE` for constants.
- Avoid wildcard imports (`from module import *`). Use explicit imports.

## 2. Function & Method Design (Small & Well-Named)
- **Single Responsibility Principle:** Every function must do exactly one thing.
- **Length Constraint:** Functions/methods must remain small (ideally under 20–25 lines of executable code).
- **Naming:** Function names must start with a descriptive verb indicating action/intent (e.g., `calculate_tax_rate`, `validate_user_payload`, `fetch_active_subscriptions`) — not generic names like `process_data` or `handle`.
- Private helpers prefixed with `_`; public API is minimal and explicit.

## 3. Documentation
- **Every** module, class, public function, and method has a Google-style docstring.
- Docstring format:
  ```python
  def foo(x: int, y: str) -> bool:
      """One-line summary.

      Longer description if needed.

      Args:
          x: What x is.
          y: What y is.

      Returns:
          What the return value means.

      Raises:
          ValueError: When and why.
      """
  ```
- Inline comments only where logic is non-obvious — don't narrate what the code already says.

## 4. Strong Typing (Strict Type Annotations)
- Provide explicit type hints for ALL function arguments, class attributes, and return values.
- Use Python 3.10+ native union/type syntax (`str | None` instead of `Optional[str]`, `list[int]` instead of `List[int]`).
- Use `Pydantic` models or `@dataclass(frozen=True)` for structured data instead of unstructured dictionaries.
- Avoid using `Any`. If a dynamic type is strictly required, wrap it in a custom type alias or generic with explicit constraints.

## 5. Modular Architecture
- Break code into single-purpose, decoupled files and modules.
- Separate core domain logic, data persistence, network/API calls, and CLI/UI into distinct modules.
- Avoid monolithic script files. Keep files under 200–250 lines where feasible.
- Group related constants, then helpers, then public functions — separated by `# ---` section headers.
- Use `__all__` in `__init__.py` files to define explicit module interfaces.

## 6. Design for Testability
- **Dependency Injection:** Pass dependencies (databases, API clients, clocks, loggers) into functions/classes rather than instantiating them internally or relying on global state.
- **Pure Functions:** Prefer deterministic pure functions (no side effects) for business logic.
- **Isolate Side Effects:** Keep I/O operations (file system, network, database) at the boundaries of the application so core logic can be tested in memory without mocks.
- **No Global State:** Do not use global mutable variables.

---

## Output Verification Checklist (Internal Mental Check)
Before presenting code, verify:
1. Are all public functions typed and documented with Google-style docstrings?
2. Can any function over 25 lines be split into smaller helper functions?
3. Is external dependency logic injected rather than hardcoded?

---

## Code Review Trigger
Whenever the user says **"review this"** or **"check design"**, perform a full Senior Engineer critique before taking any action. The critique must cover:
- Correctness: logic bugs, edge cases, off-by-one errors, missing error handling, silent failures.
- Design: SRP violations, tight coupling, missing abstractions, poor naming, leaky interfaces.
- Code smells: dead code, magic numbers, deeply nested logic, feature envy, shotgun surgery, premature optimisation, duplicated logic (DRY violations).
- Completeness: missing edge cases, unhandled states, incomplete error paths — ask "have you thought of everything?"
- Improvement opportunities: simpler algorithms, clearer data structures, better separation of concerns, performance wins that don't add complexity.
- Typing: missing or incorrect annotations, use of `Any`, untyped dictionaries.
- Testability: global state, hidden dependencies, untestable side effects.
- Style: deviations from the Google Python Style Guide, docstring gaps.

Present findings as a prioritised list (Critical → Major → Minor) before proposing any fixes.

---

## Planning Final-Review Protocol

Whenever producing an implementation plan (before writing any code), the
last step of the plan must be a dedicated final review pass — not a
summary, an actual second look:

- Re-read the full plan end-to-end as a skeptical reviewer seeing it for
  the first time, not as its author.
- Explicitly check for: off-by-one errors, unhandled edge cases (null,
  empty, boundary values), race conditions, steps that contradict earlier
  steps, and any assumption that hasn't been verified against the codebase.
- List anything flagged during this pass, however minor.
- Only then present the finalized plan.

This step is mandatory even when the plan seems simple or obviously
correct — do not skip it because the plan looks short.

---

## Style Review Protocol

Run the style-reviewer subagent once, on the final consolidated diff of the
task, right before a commit or PR — not after every individual edit, and not
on code that will still be reworked. Per-edit reviews produce stale findings
and duplicate effort. Exception: if a single small edit is the entire
deliverable, reviewing it immediately is fine — that is the pre-commit case.

---

## Git Workflow Rules

- **Never** run `git commit` or `git push` in the same round as a code change.
- **Never** run `git commit` and `git push` in the same round as each other.
- Code changes, commits, and pushes each require a separate explicit instruction from the user.
