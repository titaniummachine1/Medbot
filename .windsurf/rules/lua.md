---
trigger: always_on
---

# Windsurf Rules – Lua (Lmaobox + MCP)

## I. Core Philosophy (Non-Negotiable)

- **Self-explanatory code only.**
  If code needs a comment to explain _how_ it works, rewrite it.
- **Names over comments.**
  Express intent via function/variable names, not prose.
- **Live-first reality.**
  There is no prod/dev split. All code runs live.
- **Fail loud on undefined behavior.**
  If unexpected input would cause incorrect behavior → crash immediately.
- **Trust nothing external.**
  Only trust locals created in the current function.

---

## II. Zero Trust Protocol (CRITICAL)

**Rule:**
Trust **only** variables created with `local` inside the current function.

**External = untrusted:**

- function parameters
- globals (`G.*`, `_G`)
- `self.*`
- upvalues
- engine objects
- returns from any function

**Required pattern:**

```lua
local function example(param)
    assert(param, "example: param missing")

    local ply = entities.GetLocalPlayer()
    assert(ply and ply.IsAlive, "example: invalid LocalPlayer")

    -- Trusted zone below
end

```

- No silent fallbacks
- No `or default` for external data
- No guessing nilability

---

## III. MCP Authority (NON-NEGOTIABLE)

- **MCP is the source of truth.**
- If a symbol is not defined in the current file:
- Query MCP (`get_types`, `get_smart_context`)
- Or assert defensively

**Forbidden:**

- Guessing API behavior
- Guessing return shapes
- Guessing side effects

If MCP contradicts intuition → MCP wins
If user explicitly overrides → follow user

---

## IV. Structure & Architecture

**File layout (strict):**

1. **Imports (Top-level ONLY)**

- `require` must appear here.
- Runtime `require` (inside functions/loops) is **FORBIDDEN**.
- _Rationale: Runtime imports are the #1 cause of memory leaks._

2. Constants
3. Helpers (pure)
4. Runtime logic
5. Public API

**One module = one concern**

**Function rules:**

- Named functions only (no anonymous)
- ≤ ~40 LOC
- One axis only:
- decision **OR**
- transformation **OR**
- side effects

---

## V. Tables & State

- **No mixed tables.**
- Data-only tables OR behavior-only modules

- No logic stored inside state tables
- No mutation during iteration

**Globals (`G.*`):**

- May be written at init
- May be updated in controlled runtime paths
- Never ad-hoc

---

## VI. Engine Objects & Caching

- Engine objects are invalid by default.
- Always re-validate before use.

**Caching policy:**

- Allowed only with validity checks
- Prefer `fastPlayers` module when available
- Do not manually cache player lists if `fastPlayers` exists

---

## VII. Per-Frame Performance Rules

Default policy (chosen): **A – zero allocations enforced**

For any per-frame path:

- **NO `require` calls** (Strict Ban).
- No table creation.
- No closures.
- No string concatenation.
- No implicit allocations.

Hoist constants and reuse structures.

---

## VIII. Memory & Garbage Collection

- **Prohibited:** `collectgarbage("collect")` or full sweeps.
- _Rationale: Manual GC masks memory leaks; it does not fix them._

- **Exception:** Allowed **only** if:

1. The user explicitly requests it.
2. The AI issues a warning: _"Full GC is a band-aid. If you have to use this, you likely have a leak elsewhere (check for runtime `require`)."_

---

## IX. Error Handling

- **Assert + hard crash** when:
- Undefined behavior would occur
- Input violates assumptions

- If code would still behave correctly → assertion not required

No silent recovery.

---

## X. Comments & Documentation

- Comments are **high-level only**:
- describing intent
- describing approach

- No comments explaining line-by-line behavior

**Rule:**
If you feel the need to comment _how_ code works → simplify the code.

---

## XI. Lua Feature Restrictions

**Metatables:**

- Allowed only with explicit justification
- Never implicit magic
- Never for convenience

**Forbidden unless justified:**

- clever one-liners
- `and/or` flow tricks
- implicit returns
- abusing Lua flexibility for brevity

---

## XII. Vector Math

```lua
function normalize(v)
    return v / v:Length()
end

```

- `normalize` means **direction**, not math convenience
- Never normalize arbitrary vectors without semantic intent

---

## XIII. Deployment

- Always deploy using MCP `bundle`
- Never simulate deploy steps manually
- Bundling is atomic
- Do not bundle during debugging unless explicitly requested

---

## XIV. AI Guardrails (Failure Patterns)

Immediate rewrite if detected:

- **Runtime `require` calls** (Immediate Fail)
- **`collectgarbage()` usage** (Immediate Fail without user override)
- implicit globals
- guessed APIs
- reused names with different meaning
- abstraction at 2 uses
- silent nil handling
- unnamed magic numbers
- unclear math intent

---

## XV. Sanity Checklist (Before Deployment)

- [ ] All external data asserted
- [ ] No guessed APIs
- [ ] **No `require` inside functions**
- [ ] **No `collectgarbage` calls**
- [ ] Per-frame paths allocate nothing
- [ ] Names express intent without comments
- [ ] MCP `bundle` used
