# Para-Generate Backend Adapters

This folder contains backend adapters for the `para-generate` MCP server.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  MCP Tool: create_image(prompt, backend?, ...)              │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│  Backend Router (lib/generate-config.js)                     │
│  - Reads config from .parachute/generate.json               │
│  - Selects backend based on: explicit param > default config│
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌──────────────┬──────────────┬──────────────┬────────────────┐
│   mflux.js   │ nano-banana  │ replicate.js │  (future)      │
│  (local Mac) │   (API)      │    (API)     │                │
└──────────────┴──────────────┴──────────────┴────────────────┘
                          ↓
              Save to assets/YYYY-MM/
              Return path
```

## Backend Interface

Each backend adapter exports a function with this signature:

```javascript
export async function generate(options) {
  // options = {
  //   prompt: string,           // Required: generation prompt
  //   negative_prompt?: string, // Optional: what to avoid
  //   width?: number,           // Optional: image width (default 1024)
  //   height?: number,          // Optional: image height (default 1024)
  //   steps?: number,           // Optional: inference steps
  //   seed?: number,            // Optional: for reproducibility
  //   ...backend_specific       // Backend-specific options
  // }

  return {
    success: boolean,
    path?: string,          // Absolute path to generated file
    relativePath?: string,  // Relative path from vault root
    error?: string,         // Error message if failed
    metadata?: {
      model: string,
      steps: number,
      seed: number,
      duration_ms: number,
      ...
    }
  };
}

export const info = {
  name: 'mflux',
  displayName: 'mflux (Local)',
  description: 'Run Flux models locally on Apple Silicon',
  type: 'image',
  requirements: ['Apple Silicon Mac', 'Python 3.10+', 'mflux installed'],
  supportedModels: ['schnell', 'dev'],
};
```

## Configuration

Settings are stored in `{vault}/.parachute/generate.json`:

```json
{
  "image": {
    "default": "mflux",
    "backends": {
      "mflux": {
        "enabled": true,
        "model": "schnell",
        "steps": 4
      },
      "nano-banana": {
        "enabled": true,
        "api_key": "..."
      }
    }
  },
  "audio": {
    "default": "elevenlabs",
    "backends": {
      "acestep": { "enabled": false },
      "elevenlabs": { "enabled": true, "api_key": "..." }
    }
  }
}
```

## Adding New Backends

1. Create `lib/generate-backends/{name}.js` implementing the interface above
2. Register in `lib/generate-config.js`
3. Add to settings UI

## Content Types

- `image`: Static images (jpg, png, webp)
- `audio`: Sound effects, voice, ambient
- `music`: Musical compositions
- `speech`: Text-to-speech
- `video`: (future)
