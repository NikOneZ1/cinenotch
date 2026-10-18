import React from "react";
import { Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { colors, displayFont } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const outExpo = Easing.bezier(0.16, 1, 0.3, 1);

/** Where the inputs sit: centered, above the caption pill. */
const BOTTOM = 230;

/** Out of the way of a large island: the bottom right corner, smaller. */
const corner = { left: "auto", right: 50, bottom: 128, justifyContent: "flex-end" } as const;

/**
 * Keycaps for a shortcut, pressed at each time in `presses` (seconds into the sequence):
 * they dip and light up in the accent for a moment. They fade in just before the first press
 * and out at the end of the sequence.
 */
export const Keycaps: React.FC<{ keys: string[]; presses: number[]; durationInFrames: number; inCorner?: boolean }> = ({
  keys,
  presses,
  durationInFrames,
  inCorner,
}) => {
  const size = inCorner ? 72 : 118;
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
        gap: inCorner ? 10 : 18,
        ...(inCorner ? corner : {}),
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
            width: size,
            height: size,
            borderRadius: size * 0.22,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontFamily: displayFont,
            fontWeight: 900,
            fontSize: size * 0.49,
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

/**
 * A trackpad with two fingertips pinching, once per gesture in `pinches`: [start, end] in
 * seconds into the sequence, 1 spreading apart (bigger), -1 closing in (smaller). It sits in
 * the bottom right corner.
 */
export const Pinchpad: React.FC<{
  pinches: ReadonlyArray<readonly [number, number, 1 | -1]>;
  durationInFrames: number;
}> = ({ pinches, durationInFrames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const first = pinches[0][0];
  const active = pinches.find(([start, end]) => t >= start - 0.25 && t <= end + 0.3);
  const progress = active
    ? interpolate(t, [active[0], active[1]], [0, 1], { ...clamp, easing: Easing.bezier(0.45, 0, 0.25, 1) })
    : 0;
  // Distance of each fingertip from the middle, along the diagonal.
  const [near, far] = [22, 68];
  const spread = active ? (active[2] === 1 ? near + (far - near) * progress : far - (far - near) * progress) : near;
  const touching = active
    ? interpolate(t, [active[0] - 0.22, active[0] - 0.08, active[1] + 0.08, active[1] + 0.25], [0, 1, 1, 0], clamp)
    : 0;
  return (
    <div
      style={{
        position: "absolute",
        right: 50,
        bottom: 128,
        opacity: interpolate(
          frame,
          [(first - 0.6) * fps, (first - 0.35) * fps, durationInFrames - 0.3 * fps, durationInFrames - 0.1 * fps],
          [0, 1, 1, 0],
          clamp,
        ),
      }}
    >
      <div
        style={{
          position: "relative",
          width: 280,
          height: 170,
          borderRadius: 26,
          background: "linear-gradient(160deg, #2A2A27, #141412)",
          boxShadow: "0 26px 60px rgba(0,0,0,0.3), inset 0 0 0 2px rgba(255,255,255,0.08)",
        }}
      >
        {[-1, 1].map((side) => (
          <div
            key={side}
            style={{
              position: "absolute",
              left: 140 - 24 + side * spread * 0.82,
              top: 85 - 24 - side * spread * 0.57,
              width: 48,
              height: 48,
              borderRadius: 24,
              background: colors.accent,
              opacity: touching,
              scale: interpolate(touching, [0, 1], [1.4, 1]),
              boxShadow: `0 0 28px ${colors.accent}99`,
            }}
          />
        ))}
      </div>
    </div>
  );
};

/**
 * The current video size in the top left corner, popping in each time it changes: `changes`
 * are [seconds, label] pairs, the first one at 0.
 */
export const SizeTag: React.FC<{ changes: ReadonlyArray<readonly [number, string]> }> = ({ changes }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const current = [...changes].reverse().find(([at]) => t >= at) ?? changes[0];
  const since = t - current[0];
  return (
    <div
      style={{
        position: "absolute",
        left: 112,
        top: 140,
        padding: "14px 30px",
        borderRadius: 999,
        fontFamily: displayFont,
        fontWeight: 900,
        fontSize: 40,
        color: colors.onAccent,
        background: colors.accent,
        boxShadow: "0 16px 40px rgba(0,0,0,0.2)",
        opacity: interpolate(t, [0.05, 0.3], [0, 1], clamp),
        scale: current[0] === 0 ? 1 : interpolate(since, [0, 0.12, 0.3], [1, 1.14, 1], clamp),
      }}
    >
      {current[1]}
    </div>
  );
};
