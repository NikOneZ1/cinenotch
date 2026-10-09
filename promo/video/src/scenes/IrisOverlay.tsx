import React from "react";
import { AbsoluteFill, Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { Eyes } from "../parts/Mascot";
import { colors } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/**
 * Before → after: the screen goes dark, the mascot's eyes open in the middle and blink, then
 * swell into an iris that opens on the new version. Sits on the cut, which is at its midpoint.
 */
export const IrisOverlay: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps, width, height, durationInFrames } = useVideoConfig();
  const t = frame / fps;
  const cut = durationInFrames / 2 / fps;
  const maxRadius = Math.hypot(width, height) / 2 + 40;
  const open = interpolate(t, [cut + 0.05, cut + 0.85], [0, 1], { ...clamp, easing: Easing.bezier(0.65, 0, 0.25, 1) });
  const radius = open * maxRadius;
  const eyesOpen =
    interpolate(t, [0.3, 0.5], [0, 1], { ...clamp, easing: Easing.spring({ damping: 14 }) }) *
    interpolate(t, [0.78, 0.84, 0.9], [1, 0.08, 1], clamp);
  return (
    <AbsoluteFill>
      <AbsoluteFill
        style={{
          background: colors.ink,
          opacity: interpolate(t, [0, 0.45], [0, 1], clamp),
          maskImage: `radial-gradient(circle ${radius}px at 50% 50%, transparent ${Math.max(0, radius - 1)}px, black ${radius + 1}px)`,
          WebkitMaskImage: `radial-gradient(circle ${radius}px at 50% 50%, transparent ${Math.max(0, radius - 1)}px, black ${radius + 1}px)`,
        }}
      />
      {open > 0 && open < 1 ? (
        <div
          style={{
            position: "absolute",
            left: width / 2 - radius,
            top: height / 2 - radius,
            width: radius * 2,
            height: radius * 2,
            borderRadius: "50%",
            border: `6px solid ${colors.accent}`,
            boxShadow: `0 0 40px ${colors.accent}AA`,
            opacity: interpolate(open, [0, 0.15, 0.85, 1], [0, 1, 0.6, 0], clamp),
          }}
        />
      ) : null}
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div
          style={{
            opacity: interpolate(t, [cut + 0.05, cut + 0.4], [1, 0], clamp),
            scale: interpolate(t, [cut - 0.05, cut + 0.45], [1, 3.2], {
              ...clamp,
              easing: Easing.bezier(0.5, 0, 0.75, 0),
              output: "perceptual-scale",
            }),
          }}
        >
          <Eyes size={110} openness={eyesOpen} look={interpolate(t, [0.55, 0.65, 0.72], [0, 10, 0], clamp)} />
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
