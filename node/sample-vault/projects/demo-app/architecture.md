# Demo App Architecture

## System Overview

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   React     │────>│   Express   │────>│ PostgreSQL  │
│  Frontend   │<────│   Backend   │<────│  Database   │
└─────────────┘     └─────────────┘     └─────────────┘
```

## Frontend Architecture

- **Components**: Functional React with hooks
- **State**: React Query for server state, Zustand for UI state
- **Routing**: React Router v6
- **Styling**: Tailwind CSS

## Backend Architecture

- **Framework**: Express.js
- **ORM**: Prisma
- **Auth**: JWT tokens with refresh rotation
- **Validation**: Zod schemas

## Database Schema

Key tables:
- `users` - User accounts
- `tasks` - Task items with status, priority, due dates
- `projects` - Task groupings
- `tags` - Flexible tagging system

## Key Patterns

1. **Repository Pattern** - Data access abstracted
2. **Service Layer** - Business logic isolation
3. **DTO Validation** - Zod at boundaries
