// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
/**
 * Public (English) types of the Disaster Walkie-Talkie plugin.
 *
 * The native layers (iOS Swift, Android Java) keep their original Turkish method and field names; `src/index.ts` maps between
 * this English API and that native contract (documented in docs/native-bridge.md). Wire-level protocol rules live in
 * `src/protocol/*` and are shared by all platforms.
 */

/** Channel id: "k0" (general channel) … "k99". Messages on a channel are readable by anyone who knows the channel id. */
export type ChannelId = string;

/** Quick status a person can broadcast. Wire values: safe = "guvende", assembly = "toplanma", help = "yardim". */
export type PersonStatus = 'safe' | 'assembly' | 'help';

/** Help-call category. Wire values: trapped = "enkaz", injured = "yarali", water-food = "su-gida", shelter = "barinma",
 *  medicine = "ilac", other = "diger". */
export type HelpType = 'trapped' | 'injured' | 'water-food' | 'shelter' | 'medicine' | 'other';

export type DeviceKind = 'iphone' | 'ipad' | 'mac' | 'android' | 'other' | 'unknown';

export type PermissionState = 'granted' | 'denied' | 'unknown';

export interface WalkieTalkieStatus {
  /** false on the web, on devices without Bluetooth LE, or when the native plugin is not installed. */
  available: boolean;
  /** Native bridge version (2 = current). */
  bridgeVersion?: number;
  running?: boolean;
  /** Number of directly connected nearby devices (a device connected over two transports counts once on iOS). */
  nearbyDevices?: number;
  online?: boolean;
  recording?: boolean;
  playingId?: string | null;
  bluetoothPermission?: PermissionState;
  microphonePermission?: PermissionState;
  /** Bluetooth radio on/off, when the platform reports it. */
  bluetoothOn?: boolean;
  channel?: ChannelId;
  /** Last status per person code on the current channel during the last 12 hours. */
  statusSummary?: { safe: number; assembly: number; help: number };
  /** iOS only: background Bluetooth listening is enabled. */
  backgroundListening?: boolean;
  /** iOS only: 3 when mesh v3 (devices, invitations, help calls) is available. Undefined on Android. */
  meshVersion?: number;
}

/** A message in the local list of the current channel (no audio payload; call `play(id)`). */
export interface WalkieTalkieMessage {
  id: string;
  channel: ChannelId;
  /** Masked sender name as carried by the message, e.g. "A*** Y*****". Empty if unknown. */
  senderName: string;
  createdAt: number;
  /** How many times the message was relayed before reaching this device. */
  hops: number;
  durationMs: number;
  /** "text/plain" for text, "audio/mp4" (iOS) or "audio/aac"/"audio/mp4" (Android) for voice. */
  mime: string;
  mine: boolean;
  uploaded?: boolean;
  text?: string;
  latitude?: number;
  longitude?: number;
  locationAt?: number;
  status?: PersonStatus;
  /** Random per-device code (not a name); used to count each person once. */
  personCode?: string;
}

/** A locally created or received message that has not been uploaded to the app's own server yet. */
export interface PendingUpload {
  id: string;
  channel: ChannelId;
  senderName: string;
  createdAt: number;
  hops: number;
  durationMs: number;
  mime: string;
  /** Voice payload (base64); empty for text messages. */
  audioBase64: string;
  mine?: boolean;
  text?: string;
  latitude?: number;
  longitude?: number;
  /** Present when the item is a help call (iOS mesh v3). */
  helpCall?: { type: HelpType; people: number; note: string };
}

/** A message coming from the app's own server that should be injected into the offline mesh. */
export interface ExternalMessage {
  id: string;
  channel: ChannelId;
  senderName: string;
  createdAt: number;
  mime: string;
  durationMs: number;
  audioBase64?: string;
  text?: string;
  latitude?: number;
  longitude?: number;
}

export interface MeshDevice {
  /** Person code; "" for a direct connection whose identity has not arrived yet (cannot be invited). */
  personCode: string;
  senderName: string;
  latitude?: number;
  longitude?: number;
  lastSeenAt: number;
  direct: boolean;
  /** 1 = direct neighbour; 2–3 = through the mesh. */
  hops: number;
  kind: DeviceKind;
  connecting?: boolean;
}

export interface MeshDevices {
  devices: MeshDevice[];
  directCount: number;
  meshCount: number;
  self?: { personCode: string; senderName: string; kind: string; latitude?: number; longitude?: number };
}

export interface Invitation {
  id: string;
  fromPersonCode: string;
  fromName: string;
  /** Private channel number 1–99. */
  channelNumber: number;
  createdAt: number;
}

export interface InvitationReply {
  id: string;
  accepted: boolean;
  personCode: string;
  name: string;
  channelNumber: number;
}

export interface HelpCall {
  id: string;
  type: HelpType;
  people: number;
  note: string;
  senderName: string;
  personCode: string;
  latitude?: number;
  longitude?: number;
  locationAt?: number;
  createdAt: number;
  hops: number;
  mine: boolean;
  /** This device said "I'm coming to help". */
  coming?: boolean;
  uploaded?: boolean;
  responders: { personCode: string; name: string; at: number }[];
}

export interface WifiAwareStatus {
  supported: boolean;
  pairedDevices: number;
  connectedDevices: number;
}

export interface StartOptions {
  channel?: ChannelId;
  channelName?: string;
  /** Full display name. It is stored on the device; only the MASKED form ("A*** Y*****") travels over the mesh. */
  displayName?: string;
  /** Shows a small diagnostics panel in the native fallback screen. */
  debugPanel?: boolean;
}

export interface WalkieTalkieEvents {
  /** Something changed (new message, connection, recording, playback). Re-read `getStatus()` / `listMessages()`. */
  changed: Record<string, never>;
  /** iOS mesh v3. */
  devices: MeshDevices;
  invitation: Invitation;
  invitationReply: InvitationReply;
  helpCall: { helpCall: HelpCall };
  channelChanged: { channel: ChannelId };
  notificationTapped: { kind: string; id: string };
}

/**
 * Optional bridge to the host application's own backend (this repository ships no server). Implement it to upload messages
 * that were created/received offline once internet is back, and to inject server-side messages into the offline mesh.
 */
export interface RelayAdapter {
  /** Upload items; resolve with the ids that were stored successfully. */
  upload(items: PendingUpload[]): Promise<string[]>;
  /** Optional: recent server messages to hand to nearby offline phones. */
  fetchRecent?(): Promise<ExternalMessage[]>;
}
