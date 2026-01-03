# Technical Decisions

## ADR-001: Use Prisma over TypeORM

**Status**: Accepted
**Date**: 2024-01-15

### Context
Need to choose an ORM for PostgreSQL.

### Decision
Use Prisma because:
- Better TypeScript integration
- Schema-first approach
- Excellent migration tooling
- Better performance for complex queries

### Consequences
- Learning curve for team
- Some raw SQL still needed for advanced queries

---

## ADR-002: JWT with Refresh Tokens

**Status**: Accepted
**Date**: 2024-01-20

### Context
Need authentication strategy for SPA.

### Decision
- Short-lived access tokens (15min)
- Long-lived refresh tokens (7 days)
- Refresh token rotation on use

### Consequences
- More complex auth flow
- Better security profile
- Need token storage strategy (httpOnly cookies)

---

## ADR-003: React Query for Data Fetching

**Status**: Accepted
**Date**: 2024-02-01

### Context
Managing server state in React.

### Decision
Use TanStack React Query:
- Automatic caching
- Background refetching
- Optimistic updates
- DevTools support

### Consequences
- Reduced boilerplate
- Must understand cache invalidation
