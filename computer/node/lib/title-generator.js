/**
 * Title Generator
 *
 * Generates concise, descriptive titles for chat sessions using Haiku.
 * Uses the Claude Agent SDK's query function for lightweight title generation.
 */

import { query } from '@anthropic-ai/claude-agent-sdk';

/**
 * Generate a title for a chat session based on the conversation
 *
 * @param {Array} messages - Array of {role, content} messages
 * @param {string} agentName - Name of the agent
 * @returns {Promise<string>} - Generated title (or null if generation fails)
 */
export async function generateSessionTitle(messages, agentName) {
  // Need at least one user message to generate a title
  if (!messages || messages.length === 0) {
    return null;
  }

  // Get the first few messages for context (limit to ~2000 chars)
  const contextMessages = [];
  let charCount = 0;
  const maxChars = 2000;

  for (const msg of messages) {
    if (charCount >= maxChars) break;
    const content = msg.content.slice(0, maxChars - charCount);
    contextMessages.push({ role: msg.role, content });
    charCount += content.length;
  }

  // Format conversation for the prompt
  const conversationText = contextMessages
    .map(m => `${m.role.toUpperCase()}: ${m.content}`)
    .join('\n\n');

  const prompt = `Generate a short, descriptive title (3-7 words) for this chat conversation with "${agentName}". The title should capture the main topic or purpose. Return ONLY the title, no quotes or explanation.

Conversation:
${conversationText}`;

  try {
    const response = query({
      prompt,
      options: {
        model: 'haiku',
        maxTokens: 50,
        // Don't give Haiku any tools - this is just for text generation
        tools: [],
        permissionMode: 'acceptEdits'
      }
    });

    // Collect the response
    let title = '';
    for await (const msg of response) {
      if (msg.type === 'assistant' && msg.message?.content) {
        for (const block of msg.message.content) {
          if (block.type === 'text') {
            title = block.text;
          }
        }
      } else if (msg.type === 'result' && msg.result) {
        title = msg.result;
      }
    }

    title = title.trim();

    // Validate title
    if (title && title.length > 0 && title.length < 100) {
      console.log(`[TitleGenerator] Generated title: "${title}"`);
      return title;
    }

    return null;
  } catch (error) {
    console.error(`[TitleGenerator] Error generating title:`, error.message);
    return null;
  }
}

export default { generateSessionTitle };
