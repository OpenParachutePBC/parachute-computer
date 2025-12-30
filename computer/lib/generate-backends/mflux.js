/**
 * mflux Backend Adapter
 *
 * Generates images using mflux (MLX port of FLUX) on Apple Silicon Macs.
 *
 * Requirements:
 * - Apple Silicon Mac (M1/M2/M3/M4)
 * - Python 3.10+
 * - mflux installed: `uv tool install mflux` or `pip install mflux`
 *
 * @see https://github.com/filipstrand/mflux
 */

import { spawn, execSync } from 'child_process';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';

// Cache the mflux-generate path once found
let mfluxPath = null;

/**
 * Find the mflux-generate command
 * Checks common installation locations since subprocess PATH may differ from shell
 */
async function findMfluxGenerate() {
  if (mfluxPath) return mfluxPath;

  const homeDir = os.homedir();
  const possiblePaths = [
    // Common uv/pip install locations
    path.join(homeDir, '.local', 'bin', 'mflux-generate'),
    // Homebrew
    '/opt/homebrew/bin/mflux-generate',
    '/usr/local/bin/mflux-generate',
    // System
    '/usr/bin/mflux-generate',
  ];

  // Check each path
  for (const p of possiblePaths) {
    try {
      await fs.access(p, fs.constants.X_OK);
      console.log(`[mflux] Found mflux-generate at: ${p}`);
      mfluxPath = p;
      return p;
    } catch {
      // Not found at this path, continue
    }
  }

  // Try `which` as fallback (works if PATH is set correctly)
  try {
    const result = execSync('which mflux-generate', { encoding: 'utf-8', timeout: 5000 });
    const foundPath = result.trim();
    if (foundPath) {
      console.log(`[mflux] Found mflux-generate via which: ${foundPath}`);
      mfluxPath = foundPath;
      return foundPath;
    }
  } catch {
    // which failed
  }

  return null;
}

/**
 * Backend info for UI/discovery
 */
export const info = {
  name: 'mflux',
  displayName: 'mflux (Local)',
  description: 'Run FLUX models locally on Apple Silicon using MLX',
  type: 'image',
  requirements: [
    'Apple Silicon Mac (M1/M2/M3/M4)',
    'Python 3.10+',
    'mflux installed via pip or uv',
  ],
  supportedModels: [
    { id: 'schnell', name: 'FLUX Schnell', description: 'Fast generation, 2-4 steps', defaultSteps: 4 },
    { id: 'dev', name: 'FLUX Dev', description: 'Higher quality, 20-50 steps', defaultSteps: 25 },
  ],
  defaultModel: 'schnell',
  supportsQuantization: true,
  quantizationOptions: [4, 8],
};

/**
 * Check if mflux is available
 *
 * @returns {Promise<{available: boolean, version?: string, error?: string}>}
 */
export async function checkAvailability() {
  const mfluxCmd = await findMfluxGenerate();

  if (!mfluxCmd) {
    return {
      available: false,
      error: 'mflux-generate command not found. Install with: uv tool install mflux',
    };
  }

  return new Promise((resolve) => {
    const proc = spawn(mfluxCmd, ['--help'], {
      timeout: 5000,
    });

    let output = '';
    proc.stdout?.on('data', (data) => { output += data.toString(); });
    proc.stderr?.on('data', (data) => { output += data.toString(); });

    proc.on('close', (code) => {
      if (code === 0 || output.includes('mflux')) {
        resolve({ available: true });
      } else {
        resolve({
          available: false,
          error: 'mflux-generate command failed. Try reinstalling: uv tool install mflux',
        });
      }
    });

    proc.on('error', (err) => {
      resolve({
        available: false,
        error: `mflux-generate error: ${err.message}`,
      });
    });
  });
}

/**
 * Generate an image using mflux
 *
 * @param {object} options - Generation options
 * @param {string} options.prompt - The image prompt
 * @param {string} options.outputPath - Absolute path for output file
 * @param {string} [options.model='schnell'] - Model to use ('schnell' or 'dev')
 * @param {number} [options.steps] - Number of inference steps
 * @param {number} [options.width=1024] - Image width
 * @param {number} [options.height=1024] - Image height
 * @param {number} [options.seed] - Random seed for reproducibility
 * @param {number} [options.quantize=8] - Quantization level (4 or 8)
 * @param {string} [options.negative_prompt] - What to avoid (limited support)
 * @returns {Promise<{success: boolean, path?: string, error?: string, metadata?: object}>}
 */
export async function generate(options) {
  const {
    prompt,
    outputPath,
    model = 'schnell',
    steps,
    width = 1024,
    height = 1024,
    seed,
    quantize = 8,
  } = options;

  // Validate required params
  if (!prompt) {
    return { success: false, error: 'Prompt is required' };
  }

  if (!outputPath) {
    return { success: false, error: 'Output path is required' };
  }

  // Determine steps based on model if not specified
  const actualSteps = steps || (model === 'schnell' ? 4 : 25);

  // Build command arguments
  const args = [
    '--model', model,
    '--prompt', prompt,
    '--steps', actualSteps.toString(),
    '--width', width.toString(),
    '--height', height.toString(),
    '--output', outputPath,
  ];

  // Add optional arguments
  if (quantize) {
    args.push('-q', quantize.toString());
  }

  if (seed !== undefined && seed !== null) {
    args.push('--seed', seed.toString());
  }

  const startTime = Date.now();

  // Find the mflux-generate command
  const mfluxCmd = await findMfluxGenerate();
  if (!mfluxCmd) {
    return {
      success: false,
      error: 'mflux-generate not found. Install with: uv tool install mflux',
    };
  }

  return new Promise((resolve) => {
    console.log(`[mflux] Generating image: ${mfluxCmd} ${args.join(' ')}`);

    // Ensure system paths are in PATH for mflux's battery check (system_profiler)
    const env = {
      ...process.env,
      PATH: `${process.env.PATH || ''}:/usr/bin:/usr/sbin:/bin:/sbin`,
    };

    const proc = spawn(mfluxCmd, args, {
      timeout: 300000, // 5 minute timeout
      env,
    });

    let stdout = '';
    let stderr = '';

    proc.stdout?.on('data', (data) => {
      stdout += data.toString();
      console.log(`[mflux] ${data.toString().trim()}`);
    });

    proc.stderr?.on('data', (data) => {
      stderr += data.toString();
      // mflux outputs progress to stderr
      const line = data.toString().trim();
      if (line) {
        console.log(`[mflux] ${line}`);
      }
    });

    proc.on('close', async (code) => {
      const durationMs = Date.now() - startTime;

      if (code !== 0) {
        console.error(`[mflux] Generation failed with code ${code}`);
        resolve({
          success: false,
          error: stderr || `mflux exited with code ${code}`,
        });
        return;
      }

      // Verify output file exists
      try {
        await fs.access(outputPath);

        resolve({
          success: true,
          path: outputPath,
          metadata: {
            backend: 'mflux',
            model,
            steps: actualSteps,
            width,
            height,
            seed: seed || null,
            quantize,
            durationMs,
          },
        });
      } catch {
        resolve({
          success: false,
          error: 'Generation completed but output file not found',
        });
      }
    });

    proc.on('error', (err) => {
      console.error(`[mflux] Process error:`, err);
      resolve({
        success: false,
        error: `Failed to start mflux: ${err.message}`,
      });
    });
  });
}

/**
 * Get setup instructions
 */
export function getSetupInstructions() {
  return {
    title: 'Install mflux',
    description: 'mflux runs FLUX models locally on Apple Silicon Macs using MLX.',
    steps: [
      {
        title: 'Install mflux',
        commands: [
          '# Using uv (recommended)',
          'uv tool install mflux',
          '',
          '# Or using pip',
          'pip install mflux',
        ],
      },
      {
        title: 'Verify installation',
        commands: ['mflux-generate --help'],
      },
      {
        title: 'Optional: Pre-download model',
        commands: [
          '# Save a quantized model for faster loading',
          'mflux-save --path ~/.mflux/schnell_8bit --model schnell --quantize 8',
        ],
      },
    ],
    notes: [
      'First generation will download the model (~12GB for schnell)',
      'Quantized models use less memory and are faster',
      '8-bit quantization has minimal quality loss',
    ],
  };
}

export default {
  info,
  generate,
  checkAvailability,
  getSetupInstructions,
};
