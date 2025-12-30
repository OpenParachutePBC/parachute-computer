/**
 * Nano Banana Pro Backend Adapter
 *
 * Generates images using Google's Gemini image models:
 * - Nano Banana: Gemini 2.5 Flash Image (fast)
 * - Nano Banana Pro: Gemini 3 Pro Image (high quality with thinking)
 *
 * @see https://ai.google.dev/gemini-api/docs/image-generation
 */

import fs from 'fs/promises';

/**
 * Backend info for UI/discovery
 */
export const info = {
  name: 'nano-banana',
  displayName: 'Nano Banana Pro (Gemini)',
  description: 'Google Gemini image generation - fast cloud API with excellent quality',
  type: 'image',
  requirements: [
    'Google AI API key (GEMINI_API_KEY)',
  ],
  supportedModels: [
    {
      id: 'gemini-2.5-flash-image',
      name: 'Nano Banana (Flash)',
      description: 'Fast generation, good for iteration',
    },
    {
      id: 'gemini-3-pro-image-preview',
      name: 'Nano Banana Pro',
      description: 'Highest quality with reasoning/thinking',
    },
  ],
  defaultModel: 'gemini-2.5-flash-image',
  supportsAspectRatio: true,
  aspectRatioOptions: ['1:1', '16:9', '9:16', '4:3', '3:4'],
};

/**
 * Check if the API is available (has valid API key)
 *
 * @param {object} config - Backend configuration
 * @returns {Promise<{available: boolean, error?: string}>}
 */
export async function checkAvailability(config = {}) {
  const apiKey = config.api_key || process.env.GEMINI_API_KEY;

  if (!apiKey) {
    return {
      available: false,
      error: 'GEMINI_API_KEY not configured. Set it in generation settings or environment.',
    };
  }

  // Quick validation - try to list models
  try {
    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models?key=${apiKey}`,
      { method: 'GET' }
    );

    if (!response.ok) {
      const error = await response.json();
      return {
        available: false,
        error: `API key invalid: ${error.error?.message || response.statusText}`,
      };
    }

    return { available: true };
  } catch (e) {
    return {
      available: false,
      error: `Failed to connect to Gemini API: ${e.message}`,
    };
  }
}

/**
 * Generate an image using Gemini
 *
 * @param {object} options - Generation options
 * @param {string} options.prompt - The image prompt
 * @param {string} options.outputPath - Absolute path for output file
 * @param {string} [options.model='gemini-2.5-flash-image'] - Model to use
 * @param {string} [options.aspect_ratio='1:1'] - Aspect ratio
 * @param {string} [options.image_size] - Resolution: '1K', '2K', '4K' (Pro only)
 * @param {object} [options.config] - Backend config with api_key
 * @returns {Promise<{success: boolean, path?: string, error?: string, metadata?: object}>}
 */
export async function generate(options) {
  const {
    prompt,
    outputPath,
    model = 'gemini-2.5-flash-image',
    aspect_ratio = '1:1',
    image_size,
    config = {},
  } = options;

  // Validate required params
  if (!prompt) {
    return { success: false, error: 'Prompt is required' };
  }

  if (!outputPath) {
    return { success: false, error: 'Output path is required' };
  }

  const apiKey = config.api_key || process.env.GEMINI_API_KEY;

  if (!apiKey) {
    return {
      success: false,
      error: 'GEMINI_API_KEY not configured',
    };
  }

  const startTime = Date.now();

  try {
    // Build request body
    // Note: aspectRatio and imageSize go inside imageConfig, not directly in generationConfig
    // See: https://ai.google.dev/gemini-api/docs/image-generation
    const requestBody = {
      contents: [{
        parts: [{
          text: prompt
        }]
      }],
      generationConfig: {
        responseModalities: ['TEXT', 'IMAGE'],
      },
    };

    // Add image config if we have aspect_ratio or image_size
    if (aspect_ratio || image_size) {
      requestBody.generationConfig.imageConfig = {};

      if (aspect_ratio) {
        requestBody.generationConfig.imageConfig.aspectRatio = aspect_ratio;
      }

      if (image_size && model.includes('pro')) {
        requestBody.generationConfig.imageConfig.imageSize = image_size;
      }
    }

    console.log(`[nano-banana] Generating image with ${model}...`);

    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(requestBody),
      }
    );

    if (!response.ok) {
      const error = await response.json();
      console.error('[nano-banana] API error:', error);
      return {
        success: false,
        error: error.error?.message || `API error: ${response.statusText}`,
      };
    }

    const result = await response.json();

    // Extract image from response
    const candidates = result.candidates || [];
    if (candidates.length === 0) {
      return {
        success: false,
        error: 'No image generated - empty response',
      };
    }

    const parts = candidates[0].content?.parts || [];
    const imagePart = parts.find(p => p.inlineData?.mimeType?.startsWith('image/'));

    if (!imagePart) {
      // Check if there's text explaining why no image
      const textPart = parts.find(p => p.text);
      return {
        success: false,
        error: textPart?.text || 'No image in response',
      };
    }

    // Decode and save image
    const imageData = imagePart.inlineData.data;
    const mimeType = imagePart.inlineData.mimeType;
    const extension = mimeType.split('/')[1] || 'png';

    // Update output path with correct extension if needed
    let finalPath = outputPath;
    if (!outputPath.endsWith(`.${extension}`)) {
      finalPath = outputPath.replace(/\.[^.]+$/, `.${extension}`);
    }

    const imageBuffer = Buffer.from(imageData, 'base64');
    await fs.writeFile(finalPath, imageBuffer);

    const durationMs = Date.now() - startTime;

    console.log(`[nano-banana] Image saved to ${finalPath} (${durationMs}ms)`);

    return {
      success: true,
      path: finalPath,
      metadata: {
        backend: 'nano-banana',
        model,
        aspect_ratio,
        image_size: image_size || null,
        mimeType,
        sizeBytes: imageBuffer.length,
        durationMs,
      },
    };
  } catch (e) {
    console.error('[nano-banana] Generation error:', e);
    return {
      success: false,
      error: `Generation failed: ${e.message}`,
    };
  }
}

/**
 * Get setup instructions
 */
export function getSetupInstructions() {
  return {
    title: 'Configure Nano Banana Pro',
    description: 'Use Google Gemini for fast, high-quality image generation.',
    steps: [
      {
        title: 'Get API Key',
        commands: [
          '# Visit Google AI Studio to get your API key:',
          '# https://aistudio.google.com/apikey',
        ],
      },
      {
        title: 'Configure in Parachute',
        commands: [
          '# Set in environment:',
          'export GEMINI_API_KEY="your-api-key"',
          '',
          '# Or configure in Settings → Generation → Nano Banana Pro',
        ],
      },
    ],
    notes: [
      'Nano Banana (Flash) is faster and cheaper',
      'Nano Banana Pro has better quality and text rendering',
      'All generated images include SynthID watermark',
    ],
  };
}

export default {
  info,
  generate,
  checkAvailability,
  getSetupInstructions,
};
