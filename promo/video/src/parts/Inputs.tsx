import React from "react";
import { Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { colors, displayFont } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const outExpo = Easing.bezier(0.16, 1, 0.3, 1);

/** Where the inputs sit: centered, above the caption pill. */
const BOTTOM = 230;

/**
 * Keycaps for a shortcut, pressed at each time in `presses` (seconds into the sequence):
 * they dip and light up in the accent for a moment. They fade in just before the first press
 * and out at the end of the sequence.
 */
export const Keycaps: React.FC<{ keys: string[]; presses: number[]; durationInFrames: number }> = ({
  keys,
  presses,
  durationInFrames,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const first = presses[0];
  // 0 at rest, 1 at the bottom of a press.
  const press = Math.max(
    ...presses.map((at) => interpolate(t, [at - 0.04, at + 0.04, at + 0.26], [0, 1, 0], clamp)),
  );
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: BOTTOM,
        display: "flex",
        justifyContent: "center",
        gap: 18,
        opacity: interpolate(
          frame,
          [(first - 0.45) * fps, (first - 0.2) * fps, durationInFrames - 0.3 * fps, durationInFrames - 0.1 * fps],
          [0, 1, 1, 0],
          clamp,
        ),
        translate: interpolate(frame, [(first - 0.45) * fps, (first - 0.1) * fps], ["0px 24px", "0px 0px"], {
          ...clamp,
          easing: outExpo,
        }),
      }}
    >
      {keys.map((key) => (
        <div
          key={key}
          style={{
            width: 118,
            height: 118,
            borderRadius: 26,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: displayFont,
            fontWeight: 900,
            fontSize: 58,
            color: press > 0.5 ? colors.onAccent : "white",
            background: press > 0.5 ? colors.accent : "#1A1A18",
            boxShadow: `0 ${14 - press * 10}px 0 #050504, 0 ${26 - press * 14}px 40px rgba(0,0,0,0.28), inset 0 0 0 2px rgba(255,255,255,${0.1 - press * 0.1})`,
            translate: `0px ${press * 10}px`,
          }}
        >
          {key}
        </div>
      ))}
    </div>
  );
};

/**
 * A trackpad with two fingertips sliding across it, once per swipe in `swipes`:
 * [start, end] in seconds into the sequence, direction 1 to the right, -1 to the left.
 */
export const Trackpad: React.FC<{
  swipes: ReadonlyArray<readonly [number, number, 1 | -1]>;
  durationInFrames: number;
}> = ({ swipes, durationInFrames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const first = swipes[0][0];
  const active = swipes.find(([start, end]) => t >= start - 0.25 && t <= end + 0.3);
  const travel = 150;
  const progress = active
    ? interpolate(t, [active[0], active[1]], [0, 1], { ...clamp, easing: Easing.bezier(0.45, 0, 0.25, 1) })
    : 0;
  const x = active ? (progress - 0.5) * travel * active[2] : 0;
  const touching = active
    ? interpolate(t, [active[0] - 0.22, active[0] - 0.08, active[1] + 0.08, active[1] + 0.25], [0, 1, 1, 0], clamp)
    : 0;
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        // Lower than the keys: the open island reaches further down than they do.
        bottom: 204,
        display: "flex",
        justifyContent: "center",
        opacity: interpolate(
          frame,
          [(first - 0.6) * fps, (first - 0.35) * fps, durationInFrames - 0.3 * fps, durationInFrames - 0.1 * fps],
          [0, 1, 1, 0],
          clamp,
        ),
        translate: interpolate(frame, [(first - 0.6) * fps, (first - 0.25) * fps], ["0px 24px", "0px 0px"], {
          ...clamp,
          easing: outExpo,
        }),
      }}
    >
      <div
        style={{
          position: "relative",
          width: 330,
          height: 188,
          borderRadius: 30,
          background: "linear-gradient(160deg, #2A2A27, #141412)",
          boxShadow: "0 26px 60px rgba(0,0,0,0.3), inset 0 0 0 2px rgba(255,255,255,0.08)",
        }}
      >
        {/* Two fingertips side by side, the right one a little higher. */}
        {[
          [-34, 6],
          [34, -6],
        ].map(([dx, dy]) => (
          <div
            key={dx}
            style={{
              position: "absolute",
              left: 165 - 27 + dx + x,
              top: 94 - 27 + dy,
              width: 54,
              height: 54,
              borderRadius: 27,
              background: colors.accent,
              opacity: touching,
              scale: interpolate(touching, [0, 1], [1.4, 1]),
              boxShadow: `0 0 30px ${colors.accent}99`,
            }}
          />
        ))}
      </div>
    </div>
  );
};
