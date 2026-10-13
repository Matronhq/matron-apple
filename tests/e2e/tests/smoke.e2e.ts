// Pre-submission smoke tests for the Matron iOS app. Each test leaves the
// app signed in, and the ones after sign-in make sure of it first, so any
// test can run on its own (`npx e2e run --grep Projects`).
import { beforeEach, describe, test, type Device } from '@e2e-dev/mobile';
import { expect } from 'e2e';
import { BASE, PASSWORD, USERNAME, eventually, injectSession, isSignedIn, query, removeSession } from './rig.ts';

// The notifications prompt shows on the first launch after an install.
async function acceptPrompts(device: Device): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      await device.alert('accept');
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 500));
    }
  }
}

describe('smoke', () => {
  test('signs in with server, username and password', async ({ app, device, screen }) => {
    removeSession();
    await app.restart();
    await acceptPrompts(device);
    await screen.getByTestId('signin.server').fill(BASE);
    await screen.getByTestId('signin.username').fill(USERNAME);
    await screen.getByTestId('signin.password').fill(PASSWORD);
    // Return ends editing; the keyboard otherwise covers the Sign in button.
    await screen.getByTestId('signin.password').press('Enter');
    await screen.getByTestId('signin.submit').tap();
    // rig.sh turns password AutoFill off; should iOS offer to save the
    // password anyway, that sheet hides the app's tree until answered.
    const chat = screen.getByText('E2E smoke chat');
    const notNow = screen.getByRole('button', { name: 'Not Now' });
    const deadline = Date.now() + 30_000;
    while (!(await chat.isVisible()) && Date.now() < deadline) {
      if (await notNow.isVisible()) await notNow.tap();
      else await new Promise((r) => setTimeout(r, 500));
    }
    await expect(chat).toBeVisible();
  });

  describe('signed in', () => {
    beforeEach(async ({ app, device }) => {
      if (!isSignedIn()) injectSession();
      await app.restart();
      await acceptPrompts(device);
    });

    test('Projects tab lists projects, not Missions', async ({ agent, screen }) => {
      await agent.act('open the Projects tab');
      await expect(screen.getByText('E2E Project')).toBeVisible();
      await agent.assert('the screen is titled Projects (not Missions) and lists a project named "E2E Project"');
    });

    test('an item thread shows its image', async ({ agent, screen }) => {
      await agent.act('open the Projects tab, open "E2E Project", then open the item "E2E item with image"');
      await expect(screen.getByText('Here is the screenshot.')).toBeVisible();
      await expect(screen.getByText(/unsupported event/i)).toHaveCount(0);
      await agent.assert(
        'the thread shows the comment "Here is the screenshot." with a picture attached: a rectangle that is orange on top and blue below, not a placeholder or an error',
        { vision: true },
      );
    });

    // The audio is a tone the app writes itself (-MatronSyntheticMic in
    // e2e.config.ts): the simulator has no microphone on a headless Mac.
    test('records and sends a voice note', async ({ agent }) => {
      const before = query("SELECT count(*) FROM events WHERE convo_id='e2e-chat' AND payload LIKE '%audio/%'")[0];
      await agent.act('open the Conversations tab, open the chat "E2E smoke chat", start a voice note with the microphone button, let it record for about three seconds, then send it with the round arrow button on the recording bar');
      await eventually(() => {
        const now = query("SELECT count(*) FROM events WHERE convo_id='e2e-chat' AND payload LIKE '%audio/%'")[0];
        return now !== before ? now : undefined;
      }, 'the voice note to reach the journal');
      await agent.assert('the latest message in the chat is a file attachment named "voice-note.m4a", and no error is shown');
    });

    test('Send now releases a queued message', async ({ agent }) => {
      await agent.act('open the Conversations tab, open the chat "E2E queued message", and tap "Send now" on the queued message card');
      const reply = await eventually(
        () => query("SELECT payload FROM events WHERE convo_id='e2e-queue' AND type='prompt_reply'")[0],
        'the Send now reply to reach the journal',
      );
      expect(JSON.parse(reply).action).toBe('send');
    });
  });
});
