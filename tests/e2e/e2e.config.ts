import type { E2EConfig } from 'e2e';
import { mobile } from '@e2e-dev/mobile';
import { createAnthropic } from '@ai-sdk/anthropic';

// Smoke tests for the Matron iOS app on the dedicated "Matron e2e"
// simulator, against the local journal rig.sh seeds. Run through
// scripts/e2e-smoke.sh, which builds the app and rebuilds the rig first.
//
// The model key comes from ANTHROPIC_API_KEY; e2e-smoke.sh reads it from
// ~/.config/matron-e2e/anthropic.key when the variable is unset.
const anthropic = createAnthropic();
const model = process.env.E2E_MODEL ?? 'claude-sonnet-5-5';

export default {
  projectId: 'matron-apple-e2e',
  targets: [
    {
      name: 'ios',
      // Pinned to our own simulator so a run never drives another session's.
      engine: mobile({ platform: 'ios', device: process.env.E2E_SIM_NAME ?? 'Matron e2e' }),
      app: {
        bundleId: 'chat.matron.app',
        // Notifications can't be pre-granted on the simulator (no TCC
        // record); the tests accept that prompt instead (acceptPrompts).
        permissions: { microphone: 'grant' },
        // The simulator records from the host's default audio input; a Mac
        // with none can't start a recording. Simulator builds write a tone
        // instead when launched with this (VoiceRecorder.swift).
        launchArguments: ['-MatronSyntheticMic'],
      },
    },
  ],
  tests: 'tests/**/*.e2e.ts',
  workers: 1,
  timeout: 240_000,
  actionTimeout: 45_000,
  assertionTimeout: 15_000,
  retries: Number(process.env.E2E_RETRIES ?? 0),
  reporters: ['list', 'markdown', 'junit'],
  agents: {
    default: {
      model: anthropic(model),
      context:
        'This is Matron, an iPhone app for following AI agent sessions. The tab bar has Coordinator, ' +
        'Projects, Decisions and Conversations. Chats are listed under Conversations. A project holds ' +
        'missions; items (questions, tasks, decisions) open into a thread of comments.',
    },
  },
} satisfies E2EConfig;
