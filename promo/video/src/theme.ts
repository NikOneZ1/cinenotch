import { loadFont as loadNunito } from "@remotion/google-fonts/Nunito";
import { loadFont as loadInter } from "@remotion/google-fonts/Inter";

/** Rounded display face, close to SF Pro Rounded used in the app. */
export const { fontFamily: displayFont } = loadNunito("normal", {
  weights: ["700", "800", "900"],
  subsets: ["latin"],
});

/** For the mock Safari page behind the island. */
export const { fontFamily: uiFont } = loadInter("normal", {
  weights: ["400", "600", "700"],
  subsets: ["latin"],
});

export const colors = {
  accent: "#C6F432",
  onAccent: "#18220A",
  ink: "#0B0B0A",
  paper: "#F3F1EA",
};

/** The video is a 1280×720 pt slice of a MacBook screen at 1.5 px per pt. */
export const SCALE = 1.5;
export const NOTCH = { width: 185 * SCALE, height: 32 * SCALE };

/** Island window recordings (`--debug-demo --debug-record`), 60 fps, transparent. */
export const footage = {
  old: { file: "old.webm", width: 990, height: 810 },
  new: { file: "new.webm", width: 1560, height: 1094 },
  /** The "keys" scene of 0.6.0: ⌃⌥⌘O, scrolling, ⌃⌥⌘P (`--debug-demo-scene keys`). */
  keys: { file: "keys.webm", width: 1560, height: 1094 },
  /** The "sizes" scene of 0.7.0: pinches and ⌃⌥⌘= / ⌃⌥⌘− (`--debug-demo-scene sizes`). */
  sizes: { file: "sizes.webm", width: 1860, height: 1304 },
} as const;

export type Version = keyof typeof footage;
