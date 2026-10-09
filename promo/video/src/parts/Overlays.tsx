import React from "react";
import { Easing, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { colors, displayFont, NOTCH } from "../theme";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

/** What happens in this shot, in a pill at the bottom. Slides in after the cut, out before the next. */
export const Caption: React.FC<{
  children: string;
  durationInFrames: number;
  icon?: "play" | "cursor" | "eye" | "pause" | "close";
}> = ({ children, durationInFrames, icon }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 96,
        display: "flex",
        justifyContent: "center",
        opacity: interpolate(frame, [0.1 * fps, 0.35 * fps, durationInFrames - 0.3 * fps, durationInFrames - 0.1 * fps], [0, 1, 1, 0], clamp),
        translate: interpolate(frame, [0.1 * fps, 0.5 * fps], ["0px 30px", "0px 0px"], {
          ...clamp,
          easing: Easing.bezier(0.16, 1, 0.3, 1),
        }),
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 18,
          padding: "20px 36px 20px 28px",
          borderRadius: 999,
          background: "rgba(11,11,10,0.86)",
          color: "white",
          fontFamily: displayFont,
          fontWeight: 800,
          fontSize: 44,
          boxShadow: "0 20px 50px rgba(0,0,0,0.25)",
        }}
      >
        {icon ? <Icon kind={icon} /> : null}
        {children}
      </div>
    </div>
  );
};

const Icon: React.FC<{ kind: "play" | "cursor" | "eye" | "pause" | "close" }> = ({ kind }) => {
  const stroke = { stroke: colors.accent, strokeWidth: 3.2, fill: "none", strokeLinecap: "round", strokeLinejoin: "round" } as const;
  return (
    <svg width={44} height={44} viewBox="0 0 24 24">
      {kind === "play" ? <path d="M8 5.5v13l10.5-6.5z" fill={colors.accent} /> : null}
      {kind === "pause" ? (
        <>
          <rect x="6.5" y="5" width="4" height="14" rx="1.2" fill={colors.accent} />
          <rect x="13.5" y="5" width="4" height="14" rx="1.2" fill={colors.accent} />
        </>
      ) : null}
      {kind === "cursor" ? <path d="M6 3.5v15l4-3.8 2.6 6 2.4-1-2.6-5.9h5.6z" fill={colors.accent} /> : null}
      {kind === "eye" ? (
        <>
          <path d="M2.5 12s3.5-6.5 9.5-6.5S21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" {...stroke} />
          <circle cx="12" cy="12" r="2.8" fill={colors.accent} />
        </>
      ) : null}
      {kind === "close" ? <path d="M7 7l10 10M17 7L7 17" {...stroke} /> : null}
    </svg>
  );
};

/** "Before" / "After" in the top left corner, under the menu bar. */
export const VersionTag: React.FC<{ label: string; highlighted?: boolean }> = ({ label, highlighted }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
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
        letterSpacing: 0.5,
        color: highlighted ? colors.onAccent : "white",
        background: highlighted ? colors.accent : "rgba(11,11,10,0.8)",
        boxShadow: "0 16px 40px rgba(0,0,0,0.2)",
        opacity: interpolate(frame, [0.15 * fps, 0.4 * fps], [0, 1], clamp),
        scale: interpolate(frame, [0.15 * fps, 0.6 * fps], [0.6, 1], {
          ...clamp,
          easing: Easing.spring({ damping: 12 }),
          output: "perceptual-scale",
        }),
      }}
    >
      {label}
    </div>
  );
};

/** Rings from the camera lens: the moment the viewer glances at it. `at` is in seconds. */
export const CameraPulse: React.FC<{ at: number }> = ({ at }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps - at;
  return (
    <>
      {[0, 0.18, 0.36].map((delay) => {
        const p = (t - delay) / 0.9;
        if (p < 0 || p > 1) return null;
        const size = 24 + p * 260;
        return (
          <div
            key={delay}
            style={{
              position: "absolute",
              left: 960 - size / 2,
              top: NOTCH.height / 2 - size / 2,
              width: size,
              height: size,
              borderRadius: "50%",
              border: `4px solid ${colors.accent}`,
              opacity: (1 - p) * 0.9,
              boxShadow: `0 0 24px ${colors.accent}88`,
            }}
          />
        );
      })}
    </>
  );
};

/** A macOS-style arrow, moved through (seconds, x, y) keyframes with an ease. */
export const Cursor: React.FC<{ path: ReadonlyArray<readonly [number, number, number]>; hideAfter?: number }> = ({
  path,
  hideAfter,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const times = path.map((p) => p[0]);
  const ease = { ...clamp, easing: Easing.bezier(0.45, 0, 0.2, 1) };
  const x = interpolate(t, times, path.map((p) => p[1]), ease);
  const y = interpolate(t, times, path.map((p) => p[2]), ease);
  const visible = hideAfter === undefined || t < hideAfter;
  return (
    <svg
      width={42}
      height={42}
      viewBox="0 0 24 24"
      style={{
        position: "absolute",
        left: x - 7,
        top: y - 3,
        opacity: visible ? interpolate(t, [path[0][0], path[0][0] + 0.15], [0, 1], clamp) : 0,
        filter: "drop-shadow(0 3px 6px rgba(0,0,0,0.3))",
      }}
    >
      <path d="M5 2.5v16.2l4.2-4 2.7 6.3 2.6-1.1-2.7-6.2h5.9z" fill="#000" stroke="#fff" strokeWidth={1.4} strokeLinejoin="round" />
    </svg>
  );
};
