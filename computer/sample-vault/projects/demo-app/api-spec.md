# Demo App API Specification

## Base URL

`/api/v1`

## Authentication

All endpoints require JWT bearer token except `/auth/*`

## Endpoints

### Tasks

```
GET    /tasks          - List tasks (paginated)
POST   /tasks          - Create task
GET    /tasks/:id      - Get task
PATCH  /tasks/:id      - Update task
DELETE /tasks/:id      - Delete task
```

### Task Schema

```typescript
interface Task {
  id: string;
  title: string;
  description?: string;
  status: 'todo' | 'in_progress' | 'done';
  priority: 'low' | 'medium' | 'high';
  dueDate?: Date;
  projectId?: string;
  tags: string[];
  createdAt: Date;
  updatedAt: Date;
}
```

### Projects

```
GET    /projects       - List projects
POST   /projects       - Create project
GET    /projects/:id   - Get project with tasks
PATCH  /projects/:id   - Update project
DELETE /projects/:id   - Delete project
```

## Error Format

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Human readable message",
    "details": {}
  }
}
```
