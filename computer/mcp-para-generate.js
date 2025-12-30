#!/usr/bin/env node
/**
 * Para-Generate MCP Server
 *
 * Provides content generation tools (images, audio, etc.) via MCP protocol.
 * Supports multiple backend adapters that can be configured per-vault.
 *
 * Image Backends:
 * - mflux: Local Mac image generation using FLUX models (Apple Silicon)
 * - nano-banana: Google Gemini API (cloud, fast)
 *
 * Tools:
 * - create_image: Generate an image with optional backend override
 * - list_image_backends: List available image generation backends
 * - check_image_backend: Check if a specific backend is available
 *
 * Usage:
 *   VAULT_PATH=/path/to/vault node mcp-para-generate.js
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as generateConfig from "./lib/generate-config.js";

// Get vault path from environment
const VAULT_PATH = process.env.VAULT_PATH || "./sample-vault";
console.error(`[MCP-Generate] Starting with VAULT_PATH: ${VAULT_PATH}`);

// Create MCP server
const server = new McpServer({
  name: "para-generate",
  version: "1.0.0",
});

/**
 * create_image - Generate an image from a text prompt
 *
 * Uses the configured default backend unless overridden.
 * Returns the path to the generated image for inline display.
 */
server.tool(
  "create_image",
  {
    prompt: z.string().describe("Text description of the image to generate"),
    backend: z.enum(["mflux", "nano-banana"]).optional().describe("Backend to use (default: configured default)"),
    model: z.string().optional().describe("Specific model to use (backend-dependent)"),
    aspect_ratio: z.enum(["1:1", "16:9", "9:16", "4:3", "3:4"]).optional().describe("Aspect ratio (default: 1:1)"),
    width: z.number().min(256).max(2048).optional().describe("Image width in pixels (mflux only)"),
    height: z.number().min(256).max(2048).optional().describe("Image height in pixels (mflux only)"),
    steps: z.number().min(1).max(50).optional().describe("Inference steps (mflux only)"),
    seed: z.number().optional().describe("Random seed for reproducibility"),
  },
  async ({ prompt, backend, model, aspect_ratio, width, height, steps, seed }) => {
    console.error(`[MCP-Generate] create_image called with prompt: "${prompt?.substring(0, 50)}..."`);
    try {
      // Determine which backend to use
      let backendName = backend;
      if (!backendName) {
        backendName = await generateConfig.getDefaultBackend(VAULT_PATH, 'image');
        if (!backendName) {
          backendName = 'mflux'; // Default to local
        }
      }

      console.error(`[MCP-Generate] Using backend: ${backendName}`);

      // Load the backend adapter
      const backendModule = await generateConfig.loadBackend('image', backendName);

      // Check availability
      const backendConfig = await generateConfig.getBackendConfig(VAULT_PATH, 'image', backendName) || {};
      const availability = await backendModule.checkAvailability(backendConfig);

      if (!availability.available) {
        return {
          content: [{
            type: "text",
            text: `Backend '${backendName}' is not available: ${availability.error}\n\nTo set up ${backendName}, see the setup instructions below:\n\n${formatSetupInstructions(backendModule.getSetupInstructions())}`
          }],
          isError: true
        };
      }

      // Generate output path
      const { absolutePath, relativePath } = await generateConfig.getOutputPath(VAULT_PATH, 'png');

      // Build generation options
      const options = {
        prompt,
        outputPath: absolutePath,
        model: model || backendConfig.model,
        config: backendConfig,
      };

      // Add backend-specific options
      if (backendName === 'mflux') {
        if (width) options.width = width;
        if (height) options.height = height;
        if (steps) options.steps = steps;
        if (seed !== undefined) options.seed = seed;
        if (backendConfig.quantize) options.quantize = backendConfig.quantize;
      } else if (backendName === 'nano-banana') {
        if (aspect_ratio) options.aspect_ratio = aspect_ratio;
        if (seed !== undefined) options.seed = seed;
      }

      console.error(`[MCP-Generate] Generating image: ${prompt.substring(0, 50)}...`);

      // Generate the image
      const result = await backendModule.generate(options);

      if (!result.success) {
        return {
          content: [{
            type: "text",
            text: `Image generation failed: ${result.error}`
          }],
          isError: true
        };
      }

      // Format success response with inline image markdown
      // IMPORTANT: Include the image markdown prominently so Claude includes it in the response
      const durationSec = (result.metadata?.durationMs / 1000).toFixed(1);
      const altText = prompt.substring(0, 100).replace(/["\n]/g, ' ');

      // Use the actual saved path from result (backend may change extension, e.g., .png -> .jpeg)
      // Convert absolute path back to relative path for markdown
      let actualRelativePath = relativePath;
      if (result.path) {
        // Extract relative path from absolute path
        const vaultPrefix = VAULT_PATH.endsWith('/') ? VAULT_PATH : VAULT_PATH + '/';
        if (result.path.startsWith(vaultPrefix)) {
          actualRelativePath = result.path.substring(vaultPrefix.length);
        } else if (result.path.startsWith(VAULT_PATH)) {
          actualRelativePath = result.path.substring(VAULT_PATH.length + 1);
        }
      }

      console.error(`[MCP-Generate] Success! Image saved to: ${actualRelativePath}`);

      return {
        content: [{
          type: "text",
          text: `IMAGE GENERATED SUCCESSFULLY. You MUST include this exact markdown in your response to display the image:\n\n![${altText}](${actualRelativePath})\n\nGeneration details: ${durationSec}s, ${backendName}, ${result.metadata?.model || 'default'}`
        }]
      };
    } catch (e) {
      console.error(`[MCP-Generate] Error:`, e);
      return {
        content: [{
          type: "text",
          text: `Generation error: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * list_image_backends - List available image generation backends
 *
 * Shows configured backends and their status.
 */
server.tool(
  "list_image_backends",
  {},
  async () => {
    try {
      const backends = await generateConfig.listBackends(VAULT_PATH, 'image');
      const defaultBackend = await generateConfig.getDefaultBackend(VAULT_PATH, 'image');

      if (backends.length === 0) {
        return {
          content: [{
            type: "text",
            text: "No image backends configured. Available backends:\n\n- **mflux**: Local FLUX on Apple Silicon\n- **nano-banana**: Google Gemini API"
          }]
        };
      }

      // Check availability for each backend
      const backendStatuses = await Promise.all(
        backends.map(async (b) => {
          try {
            const backendModule = await generateConfig.loadBackend('image', b.name);
            const availability = await backendModule.checkAvailability(b);
            return {
              ...b,
              available: availability.available,
              error: availability.error,
            };
          } catch (e) {
            return {
              ...b,
              available: false,
              error: e.message,
            };
          }
        })
      );

      const formatted = backendStatuses.map(b => {
        const status = b.available ? "✅" : "❌";
        const isDefault = b.isDefault || b.name === defaultBackend ? " (default)" : "";
        const enabled = b.enabled !== false ? "" : " [disabled]";
        const error = b.error ? `\n   Error: ${b.error}` : "";
        return `- ${status} **${b.name}**${isDefault}${enabled}${error}`;
      }).join("\n");

      return {
        content: [{
          type: "text",
          text: `## Image Generation Backends\n\n${formatted}\n\nUse \`create_image\` with \`backend: "name"\` to specify a backend.`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error listing backends: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * check_image_backend - Check if a specific backend is available
 *
 * Returns detailed status and setup instructions if not available.
 */
server.tool(
  "check_image_backend",
  {
    backend: z.enum(["mflux", "nano-banana"]).describe("Backend to check"),
  },
  async ({ backend }) => {
    try {
      const backendModule = await generateConfig.loadBackend('image', backend);
      const backendConfig = await generateConfig.getBackendConfig(VAULT_PATH, 'image', backend) || {};
      const availability = await backendModule.checkAvailability(backendConfig);

      if (availability.available) {
        return {
          content: [{
            type: "text",
            text: `## ${backend}: ✅ Available\n\nBackend is ready to use.\n\n**Info:**\n- ${backendModule.info.description}\n- Supported models: ${backendModule.info.supportedModels.map(m => m.name).join(', ')}`
          }]
        };
      }

      const instructions = formatSetupInstructions(backendModule.getSetupInstructions());

      return {
        content: [{
          type: "text",
          text: `## ${backend}: ❌ Not Available\n\n${availability.error}\n\n${instructions}`
        }]
      };
    } catch (e) {
      return {
        content: [{
          type: "text",
          text: `Error checking backend: ${e.message}`
        }],
        isError: true
      };
    }
  }
);

/**
 * Format setup instructions for display
 */
function formatSetupInstructions(instructions) {
  if (!instructions) return "";

  let text = `### ${instructions.title}\n\n`;
  text += `${instructions.description}\n\n`;

  for (const step of instructions.steps || []) {
    text += `**${step.title}:**\n`;
    for (const cmd of step.commands || []) {
      if (cmd.startsWith('#')) {
        text += `${cmd}\n`;
      } else {
        text += `\`\`\`\n${cmd}\n\`\`\`\n`;
      }
    }
    text += "\n";
  }

  if (instructions.notes?.length > 0) {
    text += "**Notes:**\n";
    for (const note of instructions.notes) {
      text += `- ${note}\n`;
    }
  }

  return text;
}

// Start the server
async function main() {
  console.error("[MCP-Generate] Initializing transport...");
  const transport = new StdioServerTransport();
  console.error("[MCP-Generate] Connecting to transport...");
  await server.connect(transport);
  console.error("[MCP-Generate] Server started - tools: create_image, list_image_backends, check_image_backend");
}

main().catch((e) => {
  console.error("[MCP-Generate] Fatal error:", e);
  process.exit(1);
});
