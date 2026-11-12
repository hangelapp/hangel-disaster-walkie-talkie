// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
/**
 * Minimal, framework-free example page for a Capacitor app (iOS/Android). Bundle it with your app's web build (Vite, etc.).
 * It shows: start on a channel, push-to-talk, short text, quick status, help call, message list, optional server sync.
 * Not a production UI — see README "Building a UI responsibly" (112 notice, accessibility, battery).
 */
import { DisasterWalkieTalkie as WT, type RelayAdapter, type WalkieTalkieMessage } from '../src/index';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function render(list: WalkieTalkieMessage[]): void {
  const ul = $('messages');
  ul.replaceChildren(
    ...list.map((m) => {
      const li = document.createElement('li');
      const who = m.mine ? 'You' : m.senderName || 'Unknown';
      const what = m.mime === 'text/plain' ? m.text ?? '' : `voice ${Math.round(m.durationMs / 1000)} s`;
      const where = m.latitude !== undefined ? ` · ${m.latitude.toFixed(4)}, ${m.longitude?.toFixed(4)}` : '';
      li.textContent = `${who}: ${what} · ${m.hops} hops${where}`;
      if (m.mime !== 'text/plain') li.onclick = () => void WT.play(m.id);
      return li;
    }),
  );
}

async function refresh(): Promise<void> {
  const s = await WT.getStatus();
  $('status').textContent = s?.available
    ? `${s.nearbyDevices ?? 0} nearby · ${s.online ? 'online' : 'offline'} · Bluetooth ${s.bluetoothPermission}`
    : 'Offline walkie-talkie is not available on this device.';
  render(await WT.listMessages());
}

/** Example adapter for YOUR backend (this repository ships no server). */
const myServer: RelayAdapter = {
  async upload(items) {
    const r = await fetch('https://example.org/api/walkie-talkie', { method: 'POST', body: JSON.stringify(items) });
    return r.ok ? items.map((i) => i.id) : [];
  },
};

export async function main(): Promise<void> {
  await WT.start({ channel: 'k0', channelName: 'General', displayName: 'Ayşe Yılmaz' }); // name is masked before use
  await WT.on('changed', () => void refresh());
  await WT.on('helpCall', ({ helpCall }) => console.log('help call nearby', helpCall.type, helpCall.people));

  const ptt = $('ptt');
  ptt.addEventListener('pointerdown', () => void WT.startRecording());
  ptt.addEventListener('pointerup', () => void WT.stopRecording());
  ptt.addEventListener('pointercancel', () => void WT.stopRecording());

  $('send').addEventListener('click', async () => {
    const box = $<HTMLInputElement>('text');
    if (await WT.sendText(box.value)) box.value = '';
  });
  $('safe').addEventListener('click', () => void WT.sendStatus('safe', 'I am safe.'));
  $('help').addEventListener('click', () => void WT.sendHelpCall({ type: 'trapped', people: 2, note: 'Under debris, block C' }));
  window.addEventListener('online', () => void WT.syncWithServer(myServer));
  window.addEventListener('pagehide', () => void WT.release());
  await refresh();
}

void main();
