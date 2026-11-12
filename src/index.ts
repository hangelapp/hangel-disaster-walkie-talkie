// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
/**
 * Disaster Walkie-Talkie — English JavaScript API for the Capacitor plugin.
 *
 * Every function is safe to call on any platform: on the web, on old native builds or when a native method is missing, it
 * resolves with an empty/neutral value instead of throwing. Native method and field names are Turkish (original hangel code);
 * the mapping is documented in docs/native-bridge.md.
 *
 * Privacy: the display name you pass is MASKED here ("Ayşe Yılmaz" → "A*** Y*****") before it reaches native code, so the full
 * name is never stored by the plugin nor sent over the mesh, on both iOS and Android.
 */
import { Capacitor, registerPlugin } from '@capacitor/core';

import type {
  ChannelId,
  DeviceKind,
  ExternalMessage,
  HelpCall,
  HelpType,
  Invitation,
  InvitationReply,
  MeshDevice,
  MeshDevices,
  PendingUpload,
  PermissionState,
  PersonStatus,
  RelayAdapter,
  StartOptions,
  WalkieTalkieEvents,
  WalkieTalkieMessage,
  WalkieTalkieStatus,
  WifiAwareStatus,
} from './definitions';
import { adMaskele } from './protocol/mesh';

export * from './definitions';
export * as frame from './protocol/frame';
export * as mesh from './protocol/mesh';
export * as channel from './protocol/channel';

/** Loose shape of native results (Turkish keys). */
type Ham = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

interface NativePlugin {
  durum(): Promise<Ham>;
  motor(o: Ham): Promise<Ham>;
  kanalSec(o: Ham): Promise<void>;
  izinIste(): Promise<Ham>;
  kayitBaslat(): Promise<Ham>;
  kayitBitir(): Promise<void>;
  metinGonder(o: Ham): Promise<void>;
  durumGonder(o: Ham): Promise<void>;
  liste(): Promise<{ mesajlar?: Ham[] }>;
  cal(o: { id: string }): Promise<void>;
  disaridan(o: { mesajlar: Ham[] }): Promise<void>;
  birak(): Promise<void>;
  ac(o: Ham): Promise<void>;
  bekleyenler(): Promise<{ mesajlar?: Ham[] }>;
  yuklendi(o: { idler: string[] }): Promise<void>;
  duyuruYay(o: Ham): Promise<void>;
  arkaPlanAyarla(o: { acik: boolean }): Promise<Ham>;
  adAyarla(o: { ad: string }): Promise<void>;
  cihazlar(): Promise<Ham>;
  davetGonder(o: { kisi: string; kanal: number }): Promise<{ id: string }>;
  davetYanitla(o: { id: string; kabul: boolean }): Promise<{ kabul: boolean; kanal?: string }>;
  davetler(): Promise<{ davetler?: Ham[] }>;
  yardimGonder(o: { tur: string; kisiSayisi: number; not: string }): Promise<{ id: string }>;
  yardimListe(): Promise<{ yardimlar?: Ham[] }>;
  yardimaGidiyorum(o: { id: string }): Promise<void>;
  waDurum(): Promise<Ham>;
  waEsles(o: { rol: string; kapat: string }): Promise<void>;
  addListener(event: string, cb: (data: Ham) => void): Promise<{ remove: () => Promise<void> }>;
}

const Native = registerPlugin<NativePlugin>('DisasterWalkieTalkie');

// ─── wire value maps ───
const STATUS_TO_WIRE: Record<PersonStatus, string> = { safe: 'guvende', assembly: 'toplanma', help: 'yardim' };
const STATUS_FROM_WIRE: Record<string, PersonStatus> = { guvende: 'safe', toplanma: 'assembly', yardim: 'help' };
const HELP_TO_WIRE: Record<HelpType, string> = {
  trapped: 'enkaz',
  injured: 'yarali',
  'water-food': 'su-gida',
  shelter: 'barinma',
  medicine: 'ilac',
  other: 'diger',
};
const HELP_FROM_WIRE: Record<string, HelpType> = Object.fromEntries(
  Object.entries(HELP_TO_WIRE).map(([k, v]) => [v, k as HelpType]),
) as Record<string, HelpType>;
const EVENT_TO_WIRE: Record<keyof WalkieTalkieEvents, string> = {
  changed: 'degisti',
  devices: 'cihazlar',
  invitation: 'davet',
  invitationReply: 'davetYaniti',
  helpCall: 'yardim',
  channelChanged: 'kanalDegisti',
  notificationTapped: 'bildirimeDokunuldu',
};

function isNative(): boolean {
  try {
    const p = Capacitor.getPlatform();
    return Capacitor.isNativePlatform() && (p === 'ios' || p === 'android');
  } catch {
    return false;
  }
}

async function safe<T>(f: () => Promise<T>, fallback: T): Promise<T> {
  if (!isNative()) return fallback;
  try {
    return (await f()) ?? fallback;
  } catch {
    return fallback;
  }
}

const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
const perm = (v: unknown): PermissionState => (v === 'var' ? 'granted' : v === 'yok' ? 'denied' : 'unknown');
const kind = (v: unknown): DeviceKind =>
  v === 'iphone' || v === 'ipad' || v === 'mac' || v === 'android' ? v : v === 'bilinmiyor' ? 'unknown' : 'other';

function toStatus(d: Ham | null | undefined): WalkieTalkieStatus | null {
  if (!d) return null;
  const o = d.durumOzet as Ham | undefined;
  return {
    available: d.kullanilabilir === true,
    bridgeVersion: num(d.surum),
    running: d.calisiyor,
    nearbyDevices: num(d.bagli),
    online: d.internetVar,
    recording: d.kayitta,
    playingId: d.calanId ?? null,
    bluetoothPermission: d.bluetoothIzni === undefined ? undefined : perm(d.bluetoothIzni),
    microphonePermission: d.mikrofonIzni === undefined ? undefined : perm(d.mikrofonIzni),
    bluetoothOn: d.bluetoothAcik,
    channel: d.kanal,
    statusSummary: o ? { safe: o.guvende ?? 0, assembly: o.toplanma ?? 0, help: o.yardim ?? 0 } : undefined,
    backgroundListening: d.arkaPlanHep ?? d.arkaPlan,
    meshVersion: num(d.agSurum),
  };
}

function toMessage(m: Ham): WalkieTalkieMessage {
  return {
    id: m.id,
    channel: m.kanal,
    senderName: adMaskele(m.ad ?? ''),
    createdAt: m.olusturulduMs,
    hops: m.atlama ?? 0,
    durationMs: m.sureMs ?? 0,
    mime: m.mime,
    mine: m.kendim === true,
    uploaded: m.yuklendi,
    text: m.metin,
    latitude: num(m.enlem),
    longitude: num(m.boylam),
    locationAt: num(m.konumMs),
    status: m.durum ? STATUS_FROM_WIRE[m.durum] : undefined,
    personCode: m.kisi,
  };
}

function toPending(m: Ham): PendingUpload {
  const y = m.yardim as Ham | undefined;
  return {
    id: m.id,
    channel: m.kanal,
    senderName: adMaskele(m.ad ?? ''),
    createdAt: m.olusturulduMs,
    hops: m.atlama ?? 0,
    durationMs: m.sureMs ?? 0,
    mime: m.mime,
    audioBase64: m.sesBase64 ?? '',
    mine: m.kendim,
    text: m.metin,
    latitude: num(m.enlem),
    longitude: num(m.boylam),
    helpCall: y ? { type: HELP_FROM_WIRE[y.tur] ?? 'other', people: y.kisiSayisi ?? 1, note: y.not ?? '' } : undefined,
  };
}

function toDevice(c: Ham): MeshDevice {
  return {
    personCode: c.kisi ?? '',
    senderName: c.ad ?? '',
    latitude: num(c.enlem),
    longitude: num(c.boylam),
    lastSeenAt: c.sonGorulmeMs,
    direct: c.dogrudan === true,
    hops: c.atlama ?? 1,
    kind: kind(c.tur),
    connecting: c.baglaniyor,
  };
}

function toDevices(d: Ham): MeshDevices {
  const ben = d.ben as Ham | undefined;
  return {
    devices: Array.isArray(d.cihazlar) ? d.cihazlar.map(toDevice) : [],
    directCount: d.dogrudanSayi ?? 0,
    meshCount: d.agdakiSayi ?? 0,
    self: ben ? { personCode: ben.kisi, senderName: ben.ad, kind: ben.tur, latitude: num(ben.enlem), longitude: num(ben.boylam) } : undefined,
  };
}

const toInvitation = (d: Ham): Invitation => ({
  id: d.id,
  fromPersonCode: d.gonderenKisi,
  fromName: d.gonderenAd,
  channelNumber: d.kanal,
  createdAt: d.t,
});

const toInvitationReply = (d: Ham): InvitationReply => ({
  id: d.id,
  accepted: d.kabul === true,
  personCode: d.kisi,
  name: d.ad,
  channelNumber: d.kanal,
});

function toHelpCall(y: Ham): HelpCall {
  return {
    id: y.id,
    type: HELP_FROM_WIRE[y.tur] ?? 'other',
    people: y.kisiSayisi ?? 1,
    note: y.not ?? '',
    senderName: y.ad ?? '',
    personCode: y.kisi ?? '',
    latitude: num(y.enlem),
    longitude: num(y.boylam),
    locationAt: num(y.konumMs),
    createdAt: y.t,
    hops: y.atlama ?? 0,
    mine: y.kendim === true,
    coming: y.gidiyorum,
    uploaded: y.yuklendi,
    responders: Array.isArray(y.gidenler) ? y.gidenler.map((g: Ham) => ({ personCode: g.kisi, name: g.ad, at: g.t })) : [],
  };
}

function convertEvent(event: keyof WalkieTalkieEvents, d: Ham): unknown {
  switch (event) {
    case 'devices':
      return toDevices(d);
    case 'invitation':
      return toInvitation(d);
    case 'invitationReply':
      return toInvitationReply(d);
    case 'helpCall':
      return { helpCall: toHelpCall((d.yardim ?? {}) as Ham) };
    case 'channelChanged':
      return { channel: d.kanal };
    case 'notificationTapped':
      return { kind: d.tur, id: d.id };
    default:
      return {};
  }
}

function location(o?: { latitude: number; longitude: number }): Ham {
  return o ? { enlem: o.latitude, boylam: o.longitude } : {};
}

export const DisasterWalkieTalkie = {
  /** True on iOS/Android when the native plugin is installed and the device supports Bluetooth LE. */
  async isAvailable(): Promise<boolean> {
    return (await this.getStatus())?.available === true;
  },

  async getStatus(): Promise<WalkieTalkieStatus | null> {
    return toStatus(await safe(() => Native.durum(), null as Ham | null));
  },

  /**
   * Starts the engine (Bluetooth LE + on iOS MultipeerConnectivity / Wi-Fi Aware) on the given channel and keeps the screen awake
   * while your walkie-talkie page is open. Call `release()` when the page closes; the engine keeps relaying in the background
   * where the OS allows it.
   */
  async start(o: StartOptions = {}): Promise<WalkieTalkieStatus | null> {
    const d = await safe(
      () =>
        Native.motor({
          kanal: o.channel ?? 'k0',
          kanalAdi: o.channelName ?? '',
          ad: adMaskele(o.displayName ?? ''),
          testPaneli: o.debugPanel === true,
        }),
      null as Ham | null,
    );
    return toStatus(d);
  },

  async setChannel(channel: ChannelId, channelName = ''): Promise<void> {
    await safe(() => Native.kanalSec({ kanal: channel, kanalAdi: channelName }), undefined);
  },

  /** Asks for Bluetooth (and on Android microphone) permission; iOS asks location/notification once on first start. */
  async requestPermissions(): Promise<WalkieTalkieStatus | null> {
    return toStatus(await safe(() => Native.izinIste(), null as Ham | null));
  },

  /** Push-to-talk: start recording (max 30 s). */
  async startRecording(): Promise<void> {
    await safe(() => Native.kayitBaslat(), null);
  },

  /** Push-to-talk: stop recording and send to nearby devices. */
  async stopRecording(): Promise<void> {
    await safe(() => Native.kayitBitir(), undefined);
  },

  /**
   * Sends a short text (≤ 280 code points). iOS attaches a fresh GPS fix itself when permission exists; Android uses the
   * `location` you pass (or none). Resolves false when the native side is missing or rejected the call.
   */
  async sendText(text: string, opts: { location?: { latitude: number; longitude: number } } = {}): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.metinGonder({ metin: text, konumla: true, ...location(opts.location) });
      return true;
    } catch {
      return false;
    }
  },

  /**
   * Broadcasts a quick status ("safe" / "at assembly point" / "need help"). `readableText` is shown as plain text by older
   * clients, so pass a sentence in the user's language.
   */
  async sendStatus(status: PersonStatus, readableText: string, opts: { location?: { latitude: number; longitude: number } } = {}): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.durumGonder({ durum: STATUS_TO_WIRE[status], metin: readableText, konumla: true, ...location(opts.location) });
      return true;
    } catch {
      return false;
    }
  },

  /** Messages of the current channel (newest first, at most 50). */
  async listMessages(): Promise<WalkieTalkieMessage[]> {
    const r = await safe(() => Native.liste(), { mesajlar: [] as Ham[] });
    return (r.mesajlar ?? []).map(toMessage);
  },

  async play(id: string): Promise<void> {
    await safe(() => Native.cal({ id }), undefined);
  },

  /** Your page is closing: screen may sleep again, native auto-play is re-enabled. The engine keeps relaying. */
  async release(): Promise<void> {
    await safe(() => Native.birak(), undefined);
  },

  /** Stores the (masked) display name for offline sending. iOS only; no-op elsewhere. */
  async setDisplayName(name: string): Promise<void> {
    const m = adMaskele(name);
    if (!m) return;
    await safe(() => Native.adAyarla({ ad: m }), undefined);
  },

  /** Opens the minimal native fallback screen (SwiftUI on iOS, an Activity on Android). */
  async openNativeScreen(o: StartOptions = {}): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.ac({ kanal: o.channel ?? 'k0', kanalAdi: o.channelName ?? '', ad: adMaskele(o.displayName ?? ''), testPaneli: o.debugPanel === true });
      return true;
    } catch {
      return false;
    }
  },

  /** iOS only: keep listening over Bluetooth LE while the app is in the background (default on). */
  async setBackgroundListening(on: boolean): Promise<WalkieTalkieStatus | null> {
    return toStatus(await safe(() => Native.arkaPlanAyarla({ acik: on }), null as Ham | null));
  },

  /** Short text announcement for people nearby (max 140 chars, lives 3 h, plain text — not encrypted). */
  async broadcastAnnouncement(o: { eventId: string; title: string; text: string }): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.duyuruYay({ etkinlikId: o.eventId, baslik: o.title, metin: o.text });
      return true;
    } catch {
      return false;
    }
  },

  // ─── optional server relay (host app's own backend) ───

  async getPendingUploads(): Promise<PendingUpload[]> {
    const r = await safe(() => Native.bekleyenler(), { mesajlar: [] as Ham[] });
    return (r.mesajlar ?? []).map(toPending);
  },

  async markUploaded(ids: string[]): Promise<void> {
    if (!ids.length) return;
    await safe(() => Native.yuklendi({ idler: ids }), undefined);
  },

  /** Hands server-side messages to nearby offline phones (max 30 per call). Sender names are masked first. */
  async injectFromServer(messages: ExternalMessage[]): Promise<void> {
    const mesajlar = messages.map((m) => ({
      id: m.id,
      kanal: m.channel,
      ad: adMaskele(m.senderName),
      olusturulduMs: m.createdAt,
      mime: m.mime,
      sureMs: m.durationMs,
      sesBase64: m.audioBase64 ?? '',
      ...(m.text !== undefined ? { metin: m.text } : {}),
      ...(m.latitude !== undefined && m.longitude !== undefined ? { enlem: m.latitude, boylam: m.longitude } : {}),
    }));
    await safe(() => Native.disaridan({ mesajlar }), undefined);
  },

  /**
   * One sync round with your backend: uploads pending items, marks the stored ones, then injects recent server messages.
   * Returns the number of uploaded items. Call it when connectivity returns.
   */
  async syncWithServer(adapter: RelayAdapter): Promise<number> {
    const pending = await this.getPendingUploads();
    let stored: string[] = [];
    if (pending.length) {
      stored = await adapter.upload(pending);
      await this.markUploaded(stored);
    }
    if (adapter.fetchRecent) await this.injectFromServer(await adapter.fetchRecent());
    return stored.length;
  },

  // ─── mesh v3 (iOS only for now) ───

  async devices(): Promise<MeshDevices> {
    const d = await safe(() => Native.cihazlar(), null as Ham | null);
    return d ? toDevices(d) : { devices: [], directCount: 0, meshCount: 0 };
  },

  /** Invites a nearby person (by person code) to a private channel 1–99. Resolves the invitation id or null. */
  async sendInvitation(personCode: string, channelNumber: number): Promise<string | null> {
    return (await safe(() => Native.davetGonder({ kisi: personCode, kanal: channelNumber }), null as { id: string } | null))?.id ?? null;
  },

  /** On accept both sides switch to the channel ("k<n>"). */
  async respondToInvitation(id: string, accept: boolean): Promise<{ accepted: boolean; channel?: ChannelId } | null> {
    const r = await safe(() => Native.davetYanitla({ id, kabul: accept }), null as { kabul: boolean; kanal?: string } | null);
    return r ? { accepted: r.kabul, channel: r.kanal } : null;
  },

  async pendingInvitations(): Promise<Invitation[]> {
    const r = await safe(() => Native.davetler(), { davetler: [] as Ham[] });
    return (r.davetler ?? []).map(toInvitation);
  },

  /** Broadcasts a help call (plain text over the mesh, with location when available; lives 24 h, up to 16 hops). */
  async sendHelpCall(o: { type: HelpType; people: number; note?: string }): Promise<string | null> {
    const r = await safe(
      () => Native.yardimGonder({ tur: HELP_TO_WIRE[o.type], kisiSayisi: o.people, not: o.note ?? '' }),
      null as { id: string } | null,
    );
    return r?.id ?? null;
  },

  async listHelpCalls(): Promise<HelpCall[]> {
    const r = await safe(() => Native.yardimListe(), { yardimlar: [] as Ham[] });
    return (r.yardimlar ?? []).map(toHelpCall);
  },

  /** Tells the caller "I'm coming to help". */
  async respondToHelpCall(id: string): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.yardimaGidiyorum({ id });
      return true;
    } catch {
      return false;
    }
  },

  // ─── Wi-Fi Aware (iOS 26+, optional) ───

  async getWifiAwareStatus(): Promise<WifiAwareStatus> {
    const d = await safe(() => Native.waDurum(), null as Ham | null);
    return { supported: d?.destek === true, pairedDevices: d?.eslesmis ?? 0, connectedDevices: d?.bagli ?? 0 };
  },

  /** Opens the system pairing sheet. role "visible": this phone can be found; "search": pick a visible phone. */
  async pairWifiAware(role: 'visible' | 'search', closeLabel = 'Close'): Promise<boolean> {
    if (!isNative()) return false;
    try {
      await Native.waEsles({ rol: role === 'visible' ? 'gorunur' : 'ara', kapat: closeLabel });
      return true;
    } catch {
      return false;
    }
  },

  // ─── events ───

  /** Subscribes to an event; resolves an unsubscribe function (no-op on the web). */
  async on<E extends keyof WalkieTalkieEvents>(event: E, cb: (data: WalkieTalkieEvents[E]) => void): Promise<() => void> {
    if (!isNative()) return () => undefined;
    try {
      const h = await Native.addListener(EVENT_TO_WIRE[event], (d) => cb(convertEvent(event, d ?? {}) as WalkieTalkieEvents[E]));
      return () => void h.remove();
    } catch {
      return () => undefined;
    }
  },
};

export default DisasterWalkieTalkie;
