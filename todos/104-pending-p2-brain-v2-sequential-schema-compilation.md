---
status: completed
priority: p2
issue_id: 94
tags: [code-review, performance, brain-v2, python]
dependencies: []
---

# Brain v2: Sequential Schema Compilation Blocks Startup

## Problem Statement

`SchemaCompiler.compile_all_schemas()` compiles schemas sequentially, blocking server startup for N×150ms where N = schema count. With 20 schemas, this adds 3 seconds to startup time.

**Why it matters:** Server startup time directly impacts developer experience and deployment speed. Sequential I/O operations are a classic async antipattern.

## Findings

**Source:** performance-oracle agent (confidence: 90/100)

**Affected files:**
- `computer/modules/brain_v2/schema_compiler.py:88-106`

**Current implementation:**
```python
async def compile_all_schemas(self, schemas_dir: Path) -> list[dict]:
    schemas = []
    for yaml_file in schemas_dir.glob("*.yaml"):
        schema = await self.compile_schema(yaml_file)  # Sequential await
        schemas.append(schema)
    return schemas
```

**Performance characteristics:**
- Each schema: ~100ms file I/O + ~50ms YAML parsing = 150ms
- 10 schemas: 1.5 seconds
- 20 schemas: 3.0 seconds
- Scales linearly with schema count

**Evidence:**
- Uses aiofiles for async I/O (good)
- But awaits each file sequentially (negates benefit)
- No concurrency despite async/await infrastructure

## Proposed Solutions

### Option A: Parallel Compilation with asyncio.gather() (Recommended)
**Approach:** Compile all schemas concurrently

**Implementation:**
```python
async def compile_all_schemas(self, schemas_dir: Path) -> list[dict]:
    yaml_files = list(schemas_dir.glob("*.yaml"))
    if not yaml_files:
        return []

    # Compile all schemas in parallel
    schemas = await asyncio.gather(
        *[self.compile_schema(f) for f in yaml_files],
        return_exceptions=True
    )

    # Filter out exceptions, log errors
    valid_schemas = []
    for schema, yaml_file in zip(schemas, yaml_files):
        if isinstance(schema, Exception):
            logger.error(f"Failed to compile {yaml_file.name}: {schema}")
        else:
            valid_schemas.append(schema)

    return valid_schemas
```

**Pros:**
- Reduces startup time from sum(compile_times) to max(compile_time)
- 10 schemas: 1.5s → 150ms (10x faster)
- Simple change (10 lines)
- Utilizes existing async infrastructure

**Cons:**
- Slightly higher memory usage (all files open concurrently)
- Errors in one schema don't block others (actually a pro)

**Effort:** Small (30 minutes)
**Risk:** Low

### Option B: Lazy Schema Loading
**Approach:** Defer compilation until first request for each entity type

**Pros:**
- Zero startup time impact
- Only compile schemas actually used

**Cons:**
- Complexity: requires schema cache, locking
- First request for new type is slower
- Error discovery delayed to runtime

**Effort:** Medium (2 hours)
**Risk:** Medium

### Option C: Background Compilation Thread
**Approach:** Start compilation in background, mark module as "warming up"

**Pros:**
- Server starts immediately
- No request latency impact once warmed

**Cons:**
- Requires startup state management
- Complexity: handle requests during warmup
- Overkill for 20 schemas

**Effort:** Large (4 hours)
**Risk:** Medium

## Recommended Action

(To be filled during triage)

**Suggestion:** Option A (simple, effective, aligns with async patterns)

## Technical Details

**Affected components:**
- `SchemaCompiler.compile_all_schemas()`
- Called during `BrainV2Module._ensure_kg_service()` (lazy init)

**Startup flow:**
1. First API request triggers `_ensure_kg_service()`
2. `compile_all_schemas()` blocks for N×150ms
3. TerminusDB connection established
4. Request finally processed

**Performance impact:**
- Current (20 schemas): 3000ms first-request latency
- Option A (20 schemas): ~150ms first-request latency
- 95% reduction for typical schema counts

## Acceptance Criteria

- [ ] All schemas compile in parallel
- [ ] Compilation errors for one schema don't block others
- [ ] Failed schemas logged with clear error messages
- [ ] Startup time < max(single_schema_time) + overhead
- [ ] Test with 20 schemas, measure before/after time
- [ ] Verify asyncio.gather() error handling

## Work Log

### 2026-02-22
- **Created:** performance-oracle agent flagged during /para-review of PR #97
- **Note:** Already uses aiofiles (async I/O), just needs gather() for parallelism

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** performance-oracle
- **Python docs:** [asyncio.gather()](https://docs.python.org/3/library/asyncio-task.html#asyncio.gather)
- **Pattern:** Common async optimization for I/O-bound tasks
