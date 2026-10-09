import React from "react";
import { AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { Mascot } from "../parts/Mascot";
import { colors, displayFont } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const outExpo = Easing.bezier(0.16, 1, 0.3, 1);

/** Openness over time: opens at `openAt`, blinks once at `blinkAt` (seconds). */
const eyes = (t: number, openAt: number, blinkAt: number) =>
  interpolate(t, [openAt, openAt + 0.18], [0, 1], { ...clamp, easing: Easing.spring({ damping: 14 }) }) *
  interpolate(t, [blinkAt, blinkAt + 0.06, blinkAt + 0.13], [1, 0.08, 1], clamp);

/** Dark opener: the mascot wakes up, then the name. */
export const IntroScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  return (
    <AbsoluteFill
      style={{ background: colors.ink, alignItems: "center", justifyContent: "center", fontFamily: displayFont, gap: 64 }}
    >
      <Mascot
        width={460}
        openness={eyes(t, 0.25, 1.2)}
        look={interpolate(t, [0.7, 0.85, 1.0, 1.1], [0, 14, 14, 0], clamp)}
        style={{
          scale: interpolate(t, [0, 0.5], [0.85, 1], { ...clamp, easing: outExpo, output: "perceptual-scale" }),
          boxShadow: "0 0 0 2px rgba(255,255,255,0.06)",
        }}
      />
      <div style={{ textAlign: "center" }}>
        <div
          style={{
            color: "white",
            fontSize: 132,
            fontWeight: 900,
            letterSpacing: -2,
            opacity: interpolate(t, [0.45, 0.8], [0, 1], clamp),
            translate: interpolate(t, [0.45, 0.9], ["0px 40px", "0px 0px"], { ...clamp, easing: outExpo }),
          }}
        >
          CineNotch
        </div>
        <div
          style={{
            color: "rgba(255,255,255,0.6)",
            fontSize: 48,
            fontWeight: 800,
            marginTop: 8,
            opacity: interpolate(t, [0.7, 1.05], [0, 1], clamp),
          }}
        >
          Before <span style={{ color: colors.accent }}>→</span> after
        </div>
      </div>
    </AbsoluteFill>
  );
};

/** Warm closer: the mascot, the name, one line. */
export const OutroScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  return (
    <AbsoluteFill
      style={{ background: colors.paper, alignItems: "center", justifyContent: "center", fontFamily: displayFont, gap: 56 }}
    >
      <Mascot
        width={420}
        openness={eyes(t, 0.2, 1.5)}
        look={interpolate(t, [0.9, 1.05, 1.3, 1.4], [0, -14, -14, 0], clamp)}
        style={{
          translate: interpolate(t, [0, 0.6], ["0px 50px", "0px 0px"], { ...clamp, easing: outExpo }),
        }}
      />
      <div style={{ textAlign: "center" }}>
        <div
          style={{
            color: colors.ink,
            fontSize: 132,
            fontWeight: 900,
            letterSpacing: -2,
            opacity: interpolate(t, [0.3, 0.65], [0, 1], clamp),
            translate: interpolate(t, [0.3, 0.8], ["0px 36px", "0px 0px"], { ...clamp, easing: outExpo }),
          }}
        >
          CineNotch
        </div>
        <div
          style={{
            color: "#6A6A6E",
            fontSize: 46,
            fontWeight: 800,
            marginTop: 6,
            opacity: interpolate(t, [0.55, 0.95], [0, 1], clamp),
          }}
        >
          Safari's Picture in Picture, tucked into the notch
        </div>
      </div>
    </AbsoluteFill>
  );
};
